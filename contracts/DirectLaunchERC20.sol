// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/* ------------------------------
   Context + ERC20 + Ownable Core
--------------------------------*/

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 internal _totalSupply;
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }
    function decimals() public pure override returns (uint8) { return 18; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), to, amount); return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount); return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount); _transfer(from, to, amount); return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0) && to != address(0), "ERC20: zero address");
        uint256 fromBal = _balances[from]; require(fromBal >= amount, "ERC20: > balance");
        unchecked { _balances[from] = fromBal - amount; _balances[to] += amount; }
        emit Transfer(from, to, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint zero");
        _totalSupply += amount; _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0) && spender != address(0), "ERC20: approve zero");
        _allowances[owner][spender] = amount; emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 cur = allowance(owner, spender);
        if (cur != type(uint256).max) {
            require(cur >= amount, "ERC20: insufficient allowance");
            unchecked { _approve(owner, spender, cur - amount); }
        }
    }
}

contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    constructor(address creator) {
        require(creator != address(0), "Zero owner");
        _owner = creator;
        emit OwnershipTransferred(address(0), creator);
    }

    function owner() public view returns (address) { return _owner; }

    modifier onlyOwner() { require(owner() == _msgSender(), "Not owner"); _; }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero addr");
        emit OwnershipTransferred(_owner, newOwner); _owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(_owner, address(0)); _owner = address(0);
    }
}

/* ------------------------------
   Dex Interfaces
--------------------------------*/

interface IDexRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,uint amountOutMin,address[] calldata path,address to,uint deadline
    ) external;
}
interface IDexFactory { function createPair(address, address) external returns (address); }

/* ------------------------------
   Direct Launch Token (Manual LP)
--------------------------------*/

contract DirectLaunchTokenManual is ERC20, Ownable {
    IDexRouter public immutable dexRouter;
    address public immutable WETH;
    address public immutable lpPair;
    address public immutable treasury;
    address public taxWallet;

    bool public tradingAllowed;
    bool public antiMevEnabled = true;
    bool public transferDelayEnabled = true;
    bool public limited = true;

    uint256 public swapTokensAtAmt;
    uint256 public launchTime;

    struct TxLimits { uint128 maxTx; uint128 maxWallet; }
    TxLimits public txLimits;

    struct DecayConfig {
        uint64 startTax;
        uint64 finalTax;
        uint64 decayStep;
        uint256 decayInterval;
    }

    struct LimitsConfig {
        uint128 startMaxTx;
        uint128 maxTxStep;
        uint128 startMaxWallet;
        uint128 maxWalletStep;
    }

    DecayConfig public decay;
    LimitsConfig public limits;

    mapping(address => bool) public exemptFromFees;
    mapping(address => bool) public exemptFromLimits;
    mapping(address => bool) public isAMMPair;
    mapping(address => uint256) private _holderLastTransferBlock;

    uint64 public constant FEE_DIVISOR = 10000; // 100% = 10000

    constructor(
        string memory name_, string memory symbol_, uint256 supply_,
        address _taxWallet, address _treasury,
        DecayConfig memory decayCfg,
        LimitsConfig memory limitsCfg,
        address creator
    ) ERC20(name_, symbol_) Ownable(creator) {
        require(decayCfg.startTax <= 3000, "Start tax >30%");
        require(decayCfg.finalTax <= 500, "Final tax >5%");
        require(_treasury != address(0) && _taxWallet != address(0), "Zero address");

        _mint(creator, supply_);
        taxWallet = _taxWallet;
        treasury = _treasury;

        dexRouter = IDexRouter(0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008); // Uniswap V2 clone update before real
        WETH = dexRouter.WETH();
        lpPair = IDexFactory(dexRouter.factory()).createPair(address(this), WETH);

        isAMMPair[lpPair] = true;
        exemptFromLimits[lpPair] = true; exemptFromLimits[creator] = true; exemptFromLimits[address(this)] = true;
        exemptFromFees[creator] = true; exemptFromFees[address(this)] = true; exemptFromFees[address(dexRouter)] = true;

        decay = decayCfg;
        limits = limitsCfg;

        txLimits.maxTx = limits.startMaxTx;
        txLimits.maxWallet = limits.startMaxWallet;

        swapTokensAtAmt = supply_ / 50000; // 0.05%

        _approve(address(this), address(dexRouter), type(uint256).max);
    }

    /* ------------------------------
       Trading Controls
    -------------------------------*/

    function enableTrading() external onlyOwner {
        require(!tradingAllowed, "Trading already enabled");
        tradingAllowed = true; launchTime = block.timestamp;
    }

    function finalizeDecay() external onlyOwner {
        txLimits.maxTx = uint128(totalSupply());
        txLimits.maxWallet = uint128(totalSupply());
        decay.startTax = decay.finalTax;
    }

    function updateMevBlockerEnabled(bool enabled) external onlyOwner { antiMevEnabled = enabled; }
    function removeTransferDelay() external onlyOwner { transferDelayEnabled = false; }

    /* ------------------------------
       Decay Logic
    -------------------------------*/

    function _applyDecay() internal {
        if (!tradingAllowed) return;
        uint256 intervals = (block.timestamp - launchTime) / decay.decayInterval;

        // Tax decay
        uint64 decayed = decay.startTax > (decay.finalTax + decay.decayStep * uint64(intervals))
            ? decay.startTax - decay.decayStep * uint64(intervals)
            : decay.finalTax;
        decay.startTax = decayed;

        // MaxTx decay
        uint128 newMaxTx = limits.startMaxTx + limits.maxTxStep * uint128(intervals);
        if (newMaxTx > totalSupply()) newMaxTx = uint128(totalSupply());
        txLimits.maxTx = newMaxTx;

        // MaxWallet decay
        uint128 newMaxWallet = limits.startMaxWallet + limits.maxWalletStep * uint128(intervals);
        if (newMaxWallet > totalSupply()) newMaxWallet = uint128(totalSupply());
        txLimits.maxWallet = newMaxWallet;
    }

    /* ------------------------------
       Core ERC20 Overrides
    -------------------------------*/

    function _transfer(address from, address to, uint256 amount) internal override {
        if (!exemptFromFees[from] && !exemptFromFees[to]) {
            require(tradingAllowed, "Trading not active");
            _applyDecay();
            amount -= _handleTax(from, to, amount);
            _checkLimits(from, to, amount);
        }
        super._transfer(from, to, amount);
    }

    function _checkLimits(address from, address to, uint256 amount) internal {
        if (limited) {
            if (isAMMPair[from] && !exemptFromLimits[to]) {
                require(amount <= txLimits.maxTx, "Max Txn");
                require(balanceOf(to) + amount <= txLimits.maxWallet, "Max Wallet");
            } else if (isAMMPair[to] && !exemptFromLimits[from]) {
                require(amount <= txLimits.maxTx, "Max Txn");
            } else if (!exemptFromLimits[to]) {
                require(balanceOf(to) + amount <= txLimits.maxWallet, "Max Wallet");
            }
            if (transferDelayEnabled && to != address(dexRouter) && to != lpPair) {
                require(_holderLastTransferBlock[tx.origin] < block.number, "Transfer Delay");
                _holderLastTransferBlock[to] = block.number; _holderLastTransferBlock[tx.origin] = block.number;
            }
        }
        if (antiMevEnabled && isAMMPair[to]) {
            require(_holderLastTransferBlock[from] < block.number, "Anti MEV");
        }
    }

/* ------------------------------
   Tax + Swap Logic
-------------------------------*/

function _handleTax(address from, address to, uint256 amount) internal returns (uint256) {
    uint64 taxRate = isAMMPair[to] || isAMMPair[from] ? decay.startTax : 0;
    if (taxRate == 0) return 0;

    // Dev tax only (treasury cut comes later from ETH split)
    uint256 taxAmt = (amount * taxRate) / FEE_DIVISOR;

    if (taxAmt > 0) {
        super._transfer(from, address(this), taxAmt);
    }

    return taxAmt;
}

function _swapTaxes() internal {
    uint256 bal = balanceOf(address(this));
    if (bal == 0) return;
    if (bal > swapTokensAtAmt * 20) bal = swapTokensAtAmt * 20;

    address[] memory path = new address[](2);
    path[0] = address(this);
    path[1] = WETH;

    // Swap tokens -> ETH into this contract
    dexRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
        bal, 0, path, address(this), block.timestamp
    );

    uint256 ethBal = address(this).balance;
    if (ethBal == 0) return;

    // Treasury skim = 5% of dev’s ETH cut
    uint256 treasuryCut = (ethBal * 500) / FEE_DIVISOR; // 5%
    uint256 devCut = ethBal - treasuryCut;

    if (treasuryCut > 0) {
        (bool ts, ) = treasury.call{value: treasuryCut}("");
        require(ts, "Treasury ETH transfer failed");
    }
    if (devCut > 0) {
        (bool tw, ) = taxWallet.call{value: devCut}("");
        require(tw, "TaxWallet ETH transfer failed");
    }
}

receive() external payable {}


}
