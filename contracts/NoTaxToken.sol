// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title NoTaxToken
 * @notice Minimal ERC20 (18 decimals) with a mint cap (`maxSupply`) enforced.
 */
contract NoTaxToken {
    // --- ERC20 basics ---
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public immutable maxSupply; // hard cap
    uint256 public totalSupply;         // minted so far

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable minter;

    // --- Events ---
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // --- Modifiers ---
    modifier onlyMinter() {
        require(msg.sender == minter, "Only minter");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply
    ) {
    // --- input validation ---
    require(bytes(_name).length > 0 && bytes(_symbol).length > 0, "Invalid name/symbol");
    require(_maxSupply > 1e18 && _maxSupply <= 1_000_000_000_000 * 1e18, "Invalid supply");

    // Initialize token metadata and record the deployer as the sole `minter`.
    // The `minter` (typically the deployer or KitchenDeployer) is authorized to
    // mint tokens during graduation. No other privileged functions exist here.
    name = _name;
    symbol = _symbol;
    maxSupply = _maxSupply;
    minter = msg.sender;
    }

    // --- Minting (Factory/Graduation via Deployer) ---
    function mint(address to, uint256 amount) external onlyMinter {
    // Mint `amount` to `to`. Enforces non-zero recipient and global `maxSupply` cap.
    // Used during graduation to allocate supply for liquidity and airdrops.
    require(to != address(0), "zero addr");
    uint256 newTotal = totalSupply + amount;
    require(newTotal <= maxSupply, "Exceeds maxSupply");
    totalSupply = newTotal;
    balanceOf[to] += amount;
    emit Transfer(address(0), to, amount);
    }

    // --- ERC20 ---
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        unchecked { allowance[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        // Internal transfer helper: basic ERC20 move of `amount` from `from` to `to`.
        // No taxes, fees, or ownership checks — this contract is intentionally minimal.
        require(to != address(0), "zero addr");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "balance");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
