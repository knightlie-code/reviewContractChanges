// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Factory.sol";

/*  
//  🥩 STEAKHOUSE — Clean. Curve. Contracts.

   SteakHouse Finance | Tax Token Contract
   📲 home:      https://steakhouse.finance
   ✖️ x:         https://x.com/steak_tech
   📤 telegram:  https://t.me/steakhouse
   🔒 locker:    https://locker.steakhouse.finance
   📈 curve:     https://curve.steakhouse.finance

   This contract is deployed by SteakHouse Finance.
   Contains only flat tax + fee logic. All limits are enforced off-chain in Kitchen.sol.
   All minting and LP actions are done via the Graduation Controller.
*/

/**
 * @title TaxToken
 * @notice ERC20 (18 decimals) with:
 *  - final tax (PERCENT, max 5%) → tokens accrue in this contract and are swapped to ETH → split across wallets
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

    // tokens held by this contract are swapped to ETH when threshold reached
    uint256 public swapThreshold;

    // --- Roles / endpoints ---
    address[4] public taxWallets;       // Up to 4 dev/marketing/revshare wallets
    uint8[4] public taxSplits;          // % shares (sum = 100)
    address public immutable steakhouseTreasury;
    address public immutable minter;
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

    // =============================================================
    // Constructor
    // =============================================================
    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _taxRate,           // PERCENT (0–5)
        address _steakhouseTreasury,
        address _router,
        address[4] memory taxWallets_,
        uint8[4] memory taxSplits_
    ) {
        // --- input validation ---
        require(bytes(_name).length > 0 && bytes(_symbol).length > 0, "Invalid name/symbol");
        require(_maxSupply > 1e18 && _maxSupply <= 1_000_000_000_000 * 1e18, "Invalid supply");
        require(_taxRate <= 5 && _taxRate >= 1, "Invalid taxRate");
        require(_steakhouseTreasury != address(0) && _router != address(0), "zero addr");

        name = _name;
        symbol = _symbol;
        maxSupply = _maxSupply;
        taxRate = _taxRate;
        steakhouseTreasury = _steakhouseTreasury;
        router = IUniswapV2Router02(_router);
        minter = msg.sender;

        // --- assign multi-wallet tax setup ---
        uint8 totalSplit = 0;
        for (uint8 i = 0; i < 4; i++) {
            taxWallets[i] = taxWallets_[i];
            taxSplits[i] = taxSplits_[i];
            totalSplit += taxSplits_[i];
        }
        require(totalSplit == 100, "Invalid tax split total");

        // --- create pair if needed ---
        address _factory = router.factory();
        address _pair = IUniswapV2Factory(_factory).getPair(address(this), router.WETH());
        if (_pair == address(0)) {
            _pair = IUniswapV2Factory(_factory).createPair(address(this), router.WETH());
        }
        pair = _pair;

        // Reasonable initial threshold (can be updated after minting)
        swapThreshold = (_maxSupply * 25) / 100_000; // 0.025%
    }

    // =============================================================
    // Admin (Factory/minter)
    // =============================================================
    function setSwapThreshold(uint256 newThreshold) external onlyMinter {
        swapThreshold = newThreshold;
        emit SwapThresholdUpdated(newThreshold);
    }

    function setTaxRate(uint256 newRatePercent) external onlyMinter {
        require(newRatePercent <= 5, "Tax > 5%");
        taxRate = newRatePercent;
        emit TaxRateUpdated(newRatePercent);
    }

    // =============================================================
    // Minting
    // =============================================================
    function mint(address to, uint256 amount) external onlyMinter {
        require(to != address(0), "zero addr");
        uint256 newTotal = totalSupply + amount;
        require(newTotal <= maxSupply, "Exceeds maxSupply");
        totalSupply = newTotal;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    // =============================================================
    // ERC20
    // =============================================================
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

    // =============================================================
    // Core transfer with taxes
    // =============================================================
    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "zero addr");
        require(amount > 0, "amount=0");

        // Swap before moving balances (avoid reentrancy)
        if (
            !swapping &&
            msg.sender != address(router) &&
            msg.sender != pair &&
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

            if (taxAmount > 0) balanceOf[address(this)] += taxAmount;
            if (feeAmount > 0) balanceOf[address(this)] += feeAmount;
        }

        // Emits
        emit Transfer(from, to, sendAmount);
        if (taxAmount > 0) emit Transfer(from, address(this), taxAmount);
        if (feeAmount > 0) emit Transfer(from, address(this), feeAmount);
    }

    // =============================================================
    // Swap accumulated tokens -> ETH and split
    // =============================================================
    function _swapBack(uint256 tokensToSwap) private {
        swapping = true;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        // Approve router if needed
        if (allowance[address(this)][address(router)] < tokensToSwap) {
            allowance[address(this)][address(router)] = type(uint256).max;
            emit Approval(address(this), address(router), type(uint256).max);
        }

        // Swap tokens -> ETH
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokensToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 ethGained = address(this).balance;

        if (ethGained > 0) {
            // Take Steakhouse 10% cut first
            uint256 steakCut = (ethGained * 10) / 100;
            uint256 remaining = ethGained - steakCut;

            if (steakCut > 0) payable(steakhouseTreasury).transfer(steakCut);

            // Distribute remainder among up to 4 wallets
            for (uint8 i = 0; i < 4; i++) {
                address wallet = taxWallets[i];
                uint8 split = taxSplits[i];
                if (wallet != address(0) && split > 0) {
                    uint256 share = (remaining * split) / 100;
                    payable(wallet).transfer(share);
                }
            }
        }

        balanceOf[address(this)] = 0;
        swapping = false;
    }
}
