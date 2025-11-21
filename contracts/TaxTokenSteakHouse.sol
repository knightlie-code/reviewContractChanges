// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Factory.sol";

/*  
//  🥩 STEAKHOUSE — Clean. Curve. Contracts.

   SteakHouse Finance | Tax Token Contract
   📲 dapp:      https://steakhouse.finance
   ✖️ x:         https://x.com/steakhouse_fi
   📤 telegram:  https://t.me/steakhouse_fi
   🔒 locker:    https://locker.steakhouse.finance
   📈 curve:     https://app.steakhouse.finance/token/[token]

   This contract is deployed by SteakHouse Finance.
   Contains only flat tax + fee logic. All limits are enforced off-chain in Kitchen.sol.
   All minting and LP actions are done via the Graduation Controller.
*/

/**
 * @title TaxToken
 * @notice ERC20 (18 decimals) with:
 *  - final tax (PERCENT, max 5%) → tokens accrue in this contract and are swapped to ETH → taxWallet
 */
contract TaxToken {
    // --- ERC20 basics ---
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public immutable maxSupply; // hard cap
    uint256 public totalSupply;         // minted so far
    address public pair;


    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // --- Fees ---
    // final tax applied on each transfer, in PERCENT (0–5)
    uint256 public taxRate; // e.g. 5 => 5%
    // platform skim to treasury on each transfer, in BPS (e.g. 30 => 0.30%)
    uint256 public constant feeRate = 30;

    // tokens held by this contract are swapped to ETH and sent to taxWallet when threshold reached
    uint256 public swapThreshold;

    // --- Roles / endpoints ---
    address public immutable taxWallet;          // receives ETH from swapBack
    address public immutable steakhouseTreasury; // receives token skim (feeRate in bps)
    address public immutable minter;             // KitchenDeployer (onlyMinter)
    IUniswapV2Router02 public immutable router;

    bool private swapping;

    // --- Events ---
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SwapThresholdUpdated(uint256 newThreshold);
    event TaxRateUpdated(uint256 newRate);

    // --- Modifiers ---
    modifier onlyMinter() {
        require(msg.sender == minter, "Only minter");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _taxRate,           // PERCENT (0–5)
        address _taxWallet,
        address _steakhouseTreasury,
        address _router
    ) {
       // --- input validation ---
       require(bytes(_name).length > 0 && bytes(_symbol).length > 0, "Invalid name/symbol");
       require(_maxSupply > 1e18 && _maxSupply <= 1_000_000_000_000 * 1e18, "Invalid supply");
       require(_taxRate <= 5 && _taxRate >= 1, "Invalid taxRate");
       require(_taxWallet != address(0) && _steakhouseTreasury != address(0) && _router != address(0), "zero addr");

        name = _name;
        symbol = _symbol;
        maxSupply = _maxSupply;
        taxRate = _taxRate;
        taxWallet = _taxWallet;
        steakhouseTreasury = _steakhouseTreasury;
        router = IUniswapV2Router02(_router);
        address _factory = router.factory();
        address _pair = IUniswapV2Factory(_factory).getPair(address(this), router.WETH());
        if (_pair == address(0)) {
            _pair = IUniswapV2Factory(_factory).createPair(address(this), router.WETH());
        }
        pair = _pair;

        minter = msg.sender;

        // Reasonable initial threshold (can be updated after minting)
        swapThreshold = (_maxSupply * 25) / 100_000; // 0.025%
    }

    // --- Admin (Factory/minter) ---
    function setSwapThreshold(uint256 newThreshold) external onlyMinter {
        swapThreshold = newThreshold;
        emit SwapThresholdUpdated(newThreshold);
    }

    function setTaxRate(uint256 newRatePercent) external onlyMinter {
        require(newRatePercent <= 5, "Tax > 5%");
        taxRate = newRatePercent;
        emit TaxRateUpdated(newRatePercent);
    }

    // --- Minting ---
    function mint(address to, uint256 amount) external onlyMinter {
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

    // --- Core transfer with taxes ---
    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "zero addr");
        require(amount > 0, "amount=0");

// Swap before moving balances (avoid reentrancy via `swapping` flag)
// Skip if msg.sender is router OR from == address(this) OR to == address(this)
if (
    !swapping &&
    msg.sender != address(router) &&
    msg.sender != pair && // exclude LP pair
    from != address(this) &&
    to != address(this)
) {
    uint256 bal = balanceOf[address(this)];
    if (bal >= swapThreshold && swapThreshold > 0) {
        _swapBack(bal);
    }
}

        uint256 fromBal = balanceOf[from];
        require(fromBal >= amount, "balance");

        // Calculate fees
        uint256 taxAmount = (amount * taxRate) / 100;        // PERCENT
        uint256 feeAmount = (amount * feeRate) / 10_000;     // BPS (0.3%)

        uint256 sendAmount = amount - taxAmount - feeAmount;

        // Effects
        unchecked {
            balanceOf[from] = fromBal - amount;
            balanceOf[to] += sendAmount;

            // Accumulate both tax + fee inside the contract
            if (taxAmount > 0) balanceOf[address(this)] += taxAmount;
            if (feeAmount > 0) balanceOf[address(this)] += feeAmount;
        }

        // Emits
        emit Transfer(from, to, sendAmount);
        if (taxAmount > 0) emit Transfer(from, address(this), taxAmount);
        if (feeAmount > 0) emit Transfer(from, address(this), feeAmount);
    }

    // --- Swap accumulated tax+fee tokens to ETH and split ---
    function _swapBack(uint256 tokensToSwap) private {
        swapping = true;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        // Approve router for max once (saves gas on repeated swaps)
        if (allowance[address(this)][address(router)] < tokensToSwap) {
            allowance[address(this)][address(router)] = type(uint256).max;
            emit Approval(address(this), address(router), type(uint256).max);
        }

        // Swap tokens -> ETH
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokensToSwap,
            0,
            path,
            address(this), // ETH comes here first
            block.timestamp
        );

        uint256 ethGained = address(this).balance;

        if (ethGained > 0) {
            // Split ETH between taxWallet and steakhouseTreasury
            uint256 totalBps = (taxRate * 100) + feeRate; // taxRate% = taxRate*100 bps
            uint256 ethToTaxWallet = (ethGained * (taxRate * 100)) / totalBps;
            uint256 ethToTreasury   = ethGained - ethToTaxWallet;

            if (ethToTaxWallet > 0) payable(taxWallet).transfer(ethToTaxWallet);
            if (ethToTreasury > 0) payable(steakhouseTreasury).transfer(ethToTreasury);
        }

        balanceOf[address(this)] = 0;
        swapping = false;
    }

}
