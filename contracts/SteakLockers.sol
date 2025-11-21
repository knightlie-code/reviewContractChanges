// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SteakLockers
/// @notice LP Locker used by the Steakhouse token deployment system
/// Locks LP tokens during V2 launch and allows creators to extend, transfer, or withdraw after lock expiry
contract SteakLockers is ReentrancyGuard {
    struct Lock {
        uint256 amount;
        uint256 unlockTime;
        address owner;
    }

    mapping(address => Lock) public lpLocks;
    address[] public lockedTokens;

    address public immutable steakhouseTreasury;
    address public authorizedCaller;
    address public owner;

    uint256 public lockFee = 0.08 ether;
    uint256 public minLpLockTime = 2_592_000; // default 30 days

    /* ===== Generic ERC-20 Locks (public) ===== */

    struct ERC20Lock {
        uint256 amount;
        uint256 unlockTime;
        address owner;
    }

    // token => incremental lockId counter
    mapping(address => uint256) public erc20LockCount;
    // token => lockId => lock data
    mapping(address => mapping(uint256 => ERC20Lock)) public erc20Locks;
    // token => list of lockIds for UI/indexing
    mapping(address => uint256[]) public erc20LockIdsByToken;

    // public-lock parameters
    uint256 public erc20LockFee = 0.0025 ether;  // default fee
    uint256 public minTokenLockTime = 1 days;    // default min lock time

    // events for ERC-20 locks
    event ERC20Locked(address indexed token, uint256 indexed lockId, address indexed owner, uint256 amount, uint256 unlockTime);
    event ERC20Unlocked(address indexed token, uint256 indexed lockId, address indexed owner, uint256 amount);
    event ERC20LockExtended(address indexed token, uint256 indexed lockId, uint256 newUnlockTime);
    event ERC20LockTransferred(address indexed token, uint256 indexed lockId, address oldOwner, address newOwner);

    // config-change events
    event Erc20LockFeeUpdated(uint256 newFee);
    event LpLockFeeUpdated(uint256 newFee);
    event MinTokenLockTimeUpdated(uint256 newTime);


    event Locked(address indexed token, address indexed owner, uint256 amount, uint256 unlockTime);
    event Unlocked(address indexed token, address indexed owner, uint256 amount);
    event LockExtended(address indexed token, uint256 newUnlockTime);
    event LockTransferred(address indexed token, address oldOwner, address newOwner);
    event CallerUpdated(address indexed newCaller);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event MinLpLockTimeUpdated(uint256 newTime);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyAuthorized() {
        require(msg.sender == authorizedCaller, "Not authorized");
        _;
    }

    constructor(address _treasury) {
        steakhouseTreasury = _treasury;
        owner = msg.sender;
    }

    /// @notice Lock LP tokens with creator ownership and a time lock
    /// @dev Called by Graduation controller (authorizedCaller) to lock LP after liquidity is added.
    function lock(address token, uint256 amount, uint256 duration, address creator) 
        external 
        payable 
        onlyAuthorized 
        nonReentrant 
    {
        require(msg.value == lockFee, "Fee is 0.08 ETH");
        require(lpLocks[token].amount == 0, "Already locked");
        // Use dynamic min lock time instead of hardcoded 30 days
        require(duration >= minLpLockTime, "Below min lock time"); 
        require(amount > 0, "Zero LP amount");

        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "LP transfer failed");

        lpLocks[token] = Lock({
            amount: amount,
            unlockTime: block.timestamp + duration,
            owner: creator
        });

        lockedTokens.push(token);

        payable(steakhouseTreasury).transfer(msg.value);
        emit Locked(token, creator, amount, block.timestamp + duration);
    }

    /// @notice Publicly lock any ERC-20 tokens for a duration. Caller becomes the lock owner.
    function lockERC20(address token, uint256 amount, uint256 duration)
        external
        payable
        nonReentrant
    {
        require(msg.value == erc20LockFee, "Fee mismatch");
        require(amount > 0, "Zero amount");
        require(duration >= minTokenLockTime, "Below min token lock time");
        require(token != address(0), "Zero token");

        // pull tokens
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        // create new lockId
        uint256 lockId = ++erc20LockCount[token];
        uint256 unlock = block.timestamp + duration;

        erc20Locks[token][lockId] = ERC20Lock({
            amount: amount,
            unlockTime: unlock,
            owner: msg.sender
        });
        erc20LockIdsByToken[token].push(lockId);

        // forward fee to treasury
        payable(steakhouseTreasury).transfer(msg.value);

        emit ERC20Locked(token, lockId, msg.sender, amount, unlock);
    }

    /// @notice Extend an ERC-20 lock you own
    function erc20ExtendLock(address token, uint256 lockId, uint256 extraTime) external {
        ERC20Lock storage L = erc20Locks[token][lockId];
        require(L.owner == msg.sender, "Not owner");
        L.unlockTime += extraTime;
        emit ERC20LockExtended(token, lockId, L.unlockTime);
    }

    /// @notice Transfer ownership of an ERC-20 lock
    function erc20TransferLockOwnership(address token, uint256 lockId, address newOwner) external {
        ERC20Lock storage L = erc20Locks[token][lockId];
        require(L.owner == msg.sender, "Not owner");
        require(newOwner != address(0), "Zero address");
        address old = L.owner;
        L.owner = newOwner;
        emit ERC20LockTransferred(token, lockId, old, newOwner);
    }

    /// @notice Withdraw full ERC-20 amount after unlock
    function erc20Withdraw(address token, uint256 lockId) external nonReentrant {
        ERC20Lock storage L = erc20Locks[token][lockId];
        require(L.owner == msg.sender, "Not owner");
        require(block.timestamp >= L.unlockTime, "Still locked");

        uint256 amt = L.amount;
        require(amt > 0, "Nothing locked");

        // zero-out before external call
        L.amount = 0;

        require(IERC20(token).transfer(msg.sender, amt), "Transfer failed");
        emit ERC20Unlocked(token, lockId, msg.sender, amt);
    }


    /// @notice Extend an existing LP lock
    function extendLock(address token, uint256 extraTime) external {
        Lock storage l = lpLocks[token];
        require(msg.sender == l.owner, "Not owner");
        l.unlockTime += extraTime;
        emit LockExtended(token, l.unlockTime);
    }

    /// @notice Transfer lock ownership to another address
    function transferLockOwnership(address token, address newOwner) external {
        Lock storage l = lpLocks[token];
        require(msg.sender == l.owner, "Not owner");
        require(newOwner != address(0), "Zero address");

        address oldOwner = l.owner;
        l.owner = newOwner;
        emit LockTransferred(token, oldOwner, newOwner);
    }

    /// @notice Withdraw LP tokens after lock expires
function withdraw(address token) external nonReentrant {
    Lock storage l = lpLocks[token];
    require(msg.sender == l.owner, "Not owner");
    require(block.timestamp >= l.unlockTime, "Still locked");

    uint256 total = l.amount;
    require(total > 0, "No LP locked");

    // Creator can only withdraw 75%
    uint256 withdrawable = (total * 75) / 100;
    uint256 remainder = total - withdrawable;

    // Update stored lock (permanent 25% locked forever)
    l.amount = remainder;

    require(IERC20(token).transfer(msg.sender, withdrawable), "Transfer failed");

    emit Unlocked(token, msg.sender, withdrawable);
}


    /// @notice View lock data for a specific token
    function getLockInfo(address token) external view returns (uint256 amount, uint256 unlockTime, address lockOwner) {
        Lock storage l = lpLocks[token];
        return (l.amount, l.unlockTime, l.owner);
    }

    /// @notice View all locked tokens
    function getAllLockedTokens() external view returns (address[] memory) {
        return lockedTokens;
    }

    function getErc20Lock(address token, uint256 lockId) external view returns (uint256 amount, uint256 unlockTime, address lockOwner) {
        ERC20Lock storage L = erc20Locks[token][lockId];
        return (L.amount, L.unlockTime, L.owner);
    }

    function getErc20LockIds(address token) external view returns (uint256[] memory) {
        return erc20LockIdsByToken[token];
    }

    /// @notice View lock info for all LP tokens
    function getAllLockInfo() external view returns (
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory unlocks,
        address[] memory owners
    ) {
        uint256 len = lockedTokens.length;
        tokens = new address[](len);
        amounts = new uint256[](len);
        unlocks = new uint256[](len);
        owners = new address[](len);

        for (uint256 i = 0; i < len; i++) {
            address token = lockedTokens[i];
            Lock storage l = lpLocks[token];
            tokens[i] = token;
            amounts[i] = l.amount;
            unlocks[i] = l.unlockTime;
            owners[i] = l.owner;
        }
    }

    // === Admin Setters ===

    function updateMinLpLockTime(uint256 newTime) external onlyOwner {
        require(newTime > 0, "Invalid time");
        minLpLockTime = newTime;
        emit MinLpLockTimeUpdated(newTime);
    }

    function forceUpdateUnlock(address lp, uint256 newUnlockTime) external onlyOwner {
        Lock storage l = lpLocks[lp];
        require(l.amount > 0, "No lock exists");
        l.unlockTime = newUnlockTime;
        emit LockExtended(lp, newUnlockTime);
   }


    function updateAuthorizedCaller(address _caller) external onlyOwner {
        authorizedCaller = _caller;
        emit CallerUpdated(_caller);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function updateErc20LockFee(uint256 newFee) external onlyOwner {
        erc20LockFee = newFee;
        require(newFee <= 0.1 ether, "Too high");
        emit Erc20LockFeeUpdated(newFee);
    }

    function updateLpLockFee(uint256 newFee) external onlyOwner {
        lockFee = newFee;
        require(newFee <= 0.1 ether, "Too high");
        emit LpLockFeeUpdated(newFee);
    }

    function updateMinTokenLockTime(uint256 newTime) external onlyOwner {
        require(newTime > 0, "Invalid time");
        minTokenLockTime = newTime;
        emit MinTokenLockTimeUpdated(newTime);
    }


function getConfig() external view returns (
    address _treasury,
    address _authorizedCaller,
    address _owner
) {
    return (
        steakhouseTreasury,
        authorizedCaller,
        owner
    );
}


    receive() external payable {}
}
