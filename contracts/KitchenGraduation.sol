// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenStorage.sol";
import "./KitchenEvents.sol";
import "./KitchenCurveMaths.sol";

/* ----------------------- External Interfaces ----------------------- */

interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function factory() external view returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IKitchenFactory {
    function deployToken(
        string memory name,
        string memory symbol,
        address creator,
        address taxWallet,
        bool isTax,
        bool removeHeader,
        uint256 finalTaxRate,
        uint256 maxSupply
    ) external payable returns (address);

    function mintRealToken(address token, address to, uint256 amount) external;
}

interface ISteakLockers {
    function lock(address token, uint256 amount, uint256 duration, address creator) external payable;
}

interface IKitchenBondingCurve {
    function releaseGraduationETH(address token, address receiver, uint256 amount) external;
    function getDynamicStipend(uint256 holderCount) external view returns (uint256);
}

interface IKitchenUtils {
    function getVirtualPrice(address token) external view returns (uint256);
}

/* --------------------------- Contract ---------------------------- */

contract KitchenGraduation is KitchenEvents {
    using KitchenCurveMaths for uint256;

    /* ------------------------------ State ------------------------------ */

    // Core module references used during graduation orchestration.
    // - `storageContract`: centralized storage for token metadata and state
    // - `factory`: used to deploy/mint V2 tokens (via KitchenDeployer)
    // - `locker`: SteakLockers address for LP locking
    // - `router`: UniswapV2-style router used to add liquidity
    // - `steakhouseTreasury`: platform treasury receiving fees
    // - `WETH`: canonical WETH token address for pair lookup
    // - `kitchenBondingCurve`: bonding curve module to pull ETH from
    // - `utils`: helper math/fee utilities
    KitchenStorage public storageContract;
    address public factory;
    address public locker;
    address public router;
    address public steakhouseTreasury;
    address public WETH;
    address public kitchenBondingCurve;
    address public utils;

    address public owner;
    address constant DEAD = address(0xdead);

    // Fees and refunds used during graduation orchestration
    uint256 private constant HEADERLESS_FEE = 0.003 ether; // forwarded when removeHeader

    // stipend refunded to last buyer (mutable by owner). This is paid from the
    // pool after graduation to reduce the net gas cost of the buyer who
    // triggered graduation.
   

    // simple nonReentrant
    uint256 private _entered;
    modifier nonReentrant() {
        require(_entered == 0, "REENTRANT");
        _entered = 1;
        _;
        _entered = 0;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /* --------------------------- Errors --------------------------- */
    error AlreadyGraduated();
    error CapNotReached(uint256 circulating, uint256 cap);
    error FinalTaxTooHigh(uint256 rate);
    error FeesExceedPool(uint256 pool, uint256 totalFee);
    error PriceIsZero();
    error NoEthLeftForLP(uint256 pool, uint256 totalFee);
    error PoolBelowMin(uint256 pool, uint256 minRequired);
    error PoolAboveMax(uint256 pool, uint256 maxAllowed);

    /* --------------------------- Debug events --------------------------- */
    event GradDebugStart(
        address indexed token,
        KitchenStorage.CurveProfile profile,
        uint256 pool,
        uint256 circ,
        uint256 cap,
        bool isTax,
        bool removeHeader
    );

    event GradDebugMath(
        address indexed token,
        uint256 gradFee,
        uint256 lockerFee,
        uint256 headerlessFee,
        uint256 totalFee,
        uint256 priceWeiPer1e18,
        uint256 ethForLP,
        uint256 tokensToLP,
        uint256 tokenFee,
        uint256 tokensToBurn
    );

    event GradDebugReleaseRequest(
        address indexed token,
        uint256 requestedEth,
        uint256 storagePoolBefore
    );

    event GradDebugPostRelease(address indexed token, uint256 contractEthAfter);

    /* ---------------------------- Constructor ---------------------------- */

    constructor(
        address _storage,
        address _factory,
        address _locker,
        address _router,
        address _treasury,
        address _weth,
        address _kitchenBondingCurve,
        address _utils
    ) {
        owner = msg.sender;
        storageContract = KitchenStorage(_storage);
        factory = _factory;
        locker = _locker;
        router = _router;
        steakhouseTreasury = _treasury;
        WETH = _weth;
        kitchenBondingCurve = _kitchenBondingCurve;
        utils = _utils;
    }

    /* ---------------------------- Types ---------------------------- */

    struct TokenMeta {
        string name;
        string symbol;
        address creator;
        address taxWallet;
        uint256 totalSupply;
        uint256 graduationCap;
        uint256 finalTaxRate;
        KitchenStorage.TokenType tokenType;
        KitchenStorage.LPLockConfig lpConfig;
    }

    struct GradParams {
        uint256 graduationFee;
        uint256 lockerFee;
        uint256 headerlessFee;
        uint256 totalFee;
        uint256 tokenFee;
        uint256 tokensToLP;
        uint256 tokensToBurn;
        uint256 finalPrice;
        uint256 ethForLP;
    }

    /* ----------------------------- External ----------------------------- */

    // Public entrypoint to request graduation. Typically called by the
    // bonding curve (auto-graduation) or by an owner/operator script. The
    // `buyer` parameter is used to optionally refund the graduation stipend.
function graduateToken(address token, address stipendReceiver) external nonReentrant {
    _graduate(token, false, stipendReceiver);
}

    /* ---------------------------- Admin/Test ---------------------------- */

    bool public testMode;

    function setTestMode(bool on) external onlyOwner { testMode = on; }

    function forceGraduate(address token) external onlyOwner nonReentrant {
        require(testMode, "Test mode off");
        _graduate(token, true, address(0));

    }

    receive() external payable {}

    /* ------------------------------ Internal ----------------------------- */

    function _graduate(address token, bool bypassCap, address stipendReceiver) internal {
        // Read current token state and metadata. These determine whether
        // graduation may proceed and how much ETH/tokens to allocate.
        KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
        if (s.graduated) revert AlreadyGraduated();

        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        TokenMeta memory t = _readMeta(token, p);
        bool isTax = (t.tokenType == KitchenStorage.TokenType.TAX);
        bool removeHeader = _resolveRemoveHeader(token, p);

        emit GradDebugStart(token, p, s.ethPool, s.circulatingSupply, t.graduationCap, isTax, removeHeader);

        // If not bypassing checks, ensure cap and pool bounds are satisfied.
        if (!bypassCap && s.circulatingSupply < t.graduationCap) {
            revert CapNotReached(s.circulatingSupply, t.graduationCap);
        }
        if (t.finalTaxRate > 5) revert FinalTaxTooHigh(t.finalTaxRate);

        if (!bypassCap) {
            uint256 minEth = storageContract.minEthAtCap();
            uint256 maxEth = storageContract.maxEthAtCap();
            if (s.ethPool < minEth) revert PoolBelowMin(s.ethPool, minEth);
            if (s.ethPool > maxEth) revert PoolAboveMax(s.ethPool, maxEth);
        }

    // Compute detailed graduation parameters (fees, tokens to LP/burn, final price)
    GradParams memory g = _computeGradParams(token, t, s, removeHeader);
        emit GradDebugMath(
            token, g.graduationFee, g.lockerFee, g.headerlessFee, g.totalFee,
            g.finalPrice, g.ethForLP, g.tokensToLP, g.tokenFee, g.tokensToBurn
        );

        // Orchestration steps (all side-effecting):
        // 1) Pull ETH from bonding curve into this contract for fees + LP
        _pullFromCurve(token, s.ethPool, g.totalFee + g.ethForLP);

        // 2) Deploy the real V2 token (headerless or with SteakHouse header)
        address realToken = _deployRealToken(t, isTax, removeHeader, g.headerlessFee);

        // 3) Airdrop buyer balances 1:1 by instructing the deployer to mint
        _airdropBuyers(token, realToken);

        // 4) Pay platform graduation fee to treasury
        _payGradFee(g.graduationFee);

        // 5) Mint token fee to treasury (1% of circulating)
        IKitchenFactory(factory).mintRealToken(realToken, steakhouseTreasury, g.tokenFee);

        // 6) Add liquidity and handle LP (burn or lock)
        (address lpToken, uint256 liquidity) =
            _addLiquidityAndHandleLP(realToken, t.lpConfig, g.ethForLP, g.tokensToLP, t.creator, g.lockerFee);

        // 7) Burn any excess tokens beyond the minted portion
        if (g.tokensToBurn > 0) {
            IKitchenFactory(factory).mintRealToken(realToken, DEAD, g.tokensToBurn);
        }

        // Persist graduation state and bookkeeping in storage contract.
        {
            KitchenStorage.TokenState memory s2 = storageContract.getTokenState(token);
            s2.graduated = true;
            storageContract.setTokenState(token, s2);
        }

        // Set public pointers (real token address, LP address) and clear buyers list
        storageContract.markTokenGraduated(token);
        storageContract.setTokenLP(token, lpToken);
        storageContract.setRealTokenAddress(token, realToken);
        storageContract.clearBuyers(token);

// Dynamically compute stipend refund based on holder count
if (stipendReceiver != address(0)) {
    uint256 holderCount = storageContract.getBuyerCount(token);
    uint256 dynamicStipend = IKitchenBondingCurve(kitchenBondingCurve).getDynamicStipend(holderCount);

    if (dynamicStipend > 0 && address(this).balance >= dynamicStipend) {
        (bool ok, ) = payable(stipendReceiver).call{value: dynamicStipend}("");
        require(ok, "Gas refund xfer failed");
        emit GraduationStipendPaid(token, stipendReceiver, dynamicStipend);
    }
}

        emit TokenGraduated(token, t.creator, s.circulatingSupply, g.ethForLP, block.number, t.graduationCap);
        emit LPFinalized(realToken, locker, g.ethForLP, g.tokensToLP, liquidity, g.finalPrice, g.tokensToBurn);
        
    }

    function _computeGradParams(
        address token,
        TokenMeta memory t,
        KitchenStorage.TokenState memory s,
        bool removeHeader
    ) private view returns (GradParams memory g) {
        // fees (can be later made configurable)
        g.graduationFee = 0.1 ether;
        g.lockerFee     = t.lpConfig.burnLP ? 0 : 0.08 ether;
        g.headerlessFee = removeHeader ? HEADERLESS_FEE : 0;
        g.totalFee      = g.graduationFee + g.lockerFee + g.headerlessFee;

        if (s.ethPool < g.totalFee) revert FeesExceedPool(s.ethPool, g.totalFee);

        // token fee to treasury (1% of circ on curve)
        g.tokenFee   = s.circulatingSupply / 100;

        // price at cap (from utils; we’ll make sure Utils returns marginal price)
        g.finalPrice = IKitchenUtils(utils).getVirtualPrice(token);
        if (g.finalPrice == 0) revert PriceIsZero();

        // all remaining pool ETH goes to LP
        g.ethForLP = s.ethPool - g.totalFee;
        if (g.ethForLP == 0) revert NoEthLeftForLP(s.ethPool, g.totalFee);

        // tokens to pair with ETH at that price
        g.tokensToLP = (g.ethForLP * 1e18) / g.finalPrice;

        // ensure we never exceed maxSupply when we later mint fee + LP + burn remainder
        uint256 capRemaining;
        unchecked {
            capRemaining = t.totalSupply - s.circulatingSupply - g.tokenFee;
        }
        if (g.tokensToLP > capRemaining) {
            g.tokensToLP = capRemaining;
        }

        uint256 mintedPortion = s.circulatingSupply + g.tokenFee + g.tokensToLP;
        g.tokensToBurn = mintedPortion < t.totalSupply ? (t.totalSupply - mintedPortion) : 0;
    }

    function _pullFromCurve(address token, uint256 poolBefore, uint256 totalRequired) private {
        emit GradDebugReleaseRequest(token, totalRequired, poolBefore);
        IKitchenBondingCurve(kitchenBondingCurve).releaseGraduationETH(token, address(this), totalRequired);
        emit GradDebugPostRelease(token, address(this).balance);
    }

function _deployRealToken(
    TokenMeta memory t,
    bool isTax,
    bool removeHeader,
    uint256 headerlessFee
) private returns (address realToken) {
    require(t.totalSupply > 0, "Invalid totalSupply");

    if (removeHeader) {
        realToken = IKitchenFactory(factory).deployToken{value: headerlessFee}(
            t.name,
            t.symbol,
            t.creator,       
            t.taxWallet,     
            isTax,
            true,            // removeHeader
            t.finalTaxRate,
            t.totalSupply
        );
    } else {
        realToken = IKitchenFactory(factory).deployToken(
            t.name,
            t.symbol,
            t.creator,      
            t.taxWallet,    
            isTax,
            false,           // headered
            t.finalTaxRate,
            t.totalSupply
        );
    }
}



    function _airdropBuyers(address virtualToken, address realToken) private {
        address[] memory arr = storageContract.getBuyers(virtualToken);
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            address u = arr[i];
            uint256 amt = storageContract.getUserBalance(u, virtualToken);
            if (amt > 0) {
                IKitchenFactory(factory).mintRealToken(realToken, u, amt);
            }
        }
    }

    function _payGradFee(uint256 gradFee) private {
        (bool okFee, ) = payable(steakhouseTreasury).call{value: gradFee}("");
        require(okFee, "Grad fee xfer failed");
    }

    function _addLiquidityAndHandleLP(
        address realToken,
        KitchenStorage.LPLockConfig memory lp,
        uint256 ethForLP,
        uint256 tokensForLP,
        address creator,
        uint256 lockerFee
    ) private returns (address lpToken, uint256 liquidity) {
        IKitchenFactory(factory).mintRealToken(realToken, address(this), tokensForLP);
        IERC20(realToken).approve(router, tokensForLP);

        (, , liquidity) = IUniswapV2Router02(router).addLiquidityETH{value: ethForLP}(
            realToken,
            tokensForLP,
            0,
            0,
            address(this),
            block.timestamp
        );

        lpToken = IUniswapV2Factory(IUniswapV2Router02(router).factory()).getPair(realToken, WETH);

        if (lp.burnLP) {
            IERC20(lpToken).transfer(DEAD, liquidity);
            emit LPBurned(realToken, liquidity, block.timestamp);
        } else {
            IERC20(lpToken).approve(locker, liquidity);
            ISteakLockers(locker).lock{value: lockerFee}(lpToken, liquidity, lp.lpLockDuration, creator);
            emit LockedLP(realToken, locker, ethForLP, liquidity, block.timestamp + lp.lpLockDuration);
        }
    }

    /* ------------------------------ Helpers ------------------------------ */

function _readMeta(address token, KitchenStorage.CurveProfile p)
    internal
    view
    returns (TokenMeta memory t)
{
    if (p == KitchenStorage.CurveProfile.ADVANCED) {
        KitchenStorage.TokenAdvanced memory a = storageContract.getTokenAdvanced(token);
        t = TokenMeta(
            a.name,
            a.symbol,
            a.creator,
            a.taxWallet,   // actual stored tax wallet
            a.totalSupply,
            a.graduationCap,
            a.finalTaxRate,
            a.tokenType,
            a.lpConfig
        );
    } else if (p == KitchenStorage.CurveProfile.BASIC) {
        KitchenStorage.TokenBasic memory b = storageContract.getTokenBasic(token);
        t = TokenMeta(
            b.name,
            b.symbol,
            b.creator,
            b.creator,     // fallback taxWallet = creator
            b.totalSupply,
            b.graduationCap,
            b.finalTaxRate,
            b.tokenType,
            b.lpConfig
        );
    } else if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) {
        KitchenStorage.TokenSuperSimple memory m = storageContract.getTokenSuperSimple(token);
        t = TokenMeta(
            m.name,
            m.symbol,
            m.creator,
            m.creator,     // fallback taxWallet = creator
            m.totalSupply,
            m.graduationCap,
            m.finalTaxRate,
            m.tokenType,
            m.lpConfig
        );
    } else {
        KitchenStorage.TokenZeroSimple memory z = storageContract.getTokenZeroSimple(token);
        t = TokenMeta(
            z.name,
            z.symbol,
            z.creator,
            z.creator,     // fallback taxWallet = creator
            z.totalSupply,
            z.graduationCap,
            z.finalTaxRate,
            z.tokenType,
            z.lpConfig
        );
    }
}


    function _resolveRemoveHeader(address token, KitchenStorage.CurveProfile p) internal view returns (bool) {
        if (storageContract.removeHeaderOnDeploy(token)) return true;

        if (p == KitchenStorage.CurveProfile.ADVANCED) {
            return storageContract.getTokenAdvanced(token).removeHeader;
        } else if (p == KitchenStorage.CurveProfile.BASIC) {
            return storageContract.getTokenBasic(token).removeHeader;
        } else if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) {
            return storageContract.getTokenSuperSimple(token).removeHeader;
        } else {
            return storageContract.getTokenZeroSimple(token).removeHeader;
        }
    }

    /* -------------------- Read-only preview -------------------- */

    struct GradPreview {
        KitchenStorage.CurveProfile profile;
        bool isTax;
        bool removeHeader;
        uint256 pool;
        uint256 circ;
        uint256 cap;
        uint256 gradFee;
        uint256 lockerFee;
        uint256 headerlessFee;
        uint256 totalFee;
        uint256 priceWeiPer1e18;
        uint256 ethForLP;
        uint256 tokensToLP;
        uint256 tokenFee;
        uint256 tokensToBurn;
    }

    function previewGraduation(address token) external view returns (GradPreview memory r) {
        KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        TokenMeta memory t = _readMeta(token, p);
        bool removeHeader = _resolveRemoveHeader(token, p);
        bool isTax = (t.tokenType == KitchenStorage.TokenType.TAX);

        r.profile = p;
        r.isTax   = isTax;
        r.removeHeader = removeHeader;
        r.pool    = s.ethPool;
        r.circ    = s.circulatingSupply;
        r.cap     = t.graduationCap;

        r.gradFee       = 0.1 ether;
        r.lockerFee     = t.lpConfig.burnLP ? 0 : 0.08 ether;
        r.headerlessFee = removeHeader ? HEADERLESS_FEE : 0;
        r.totalFee      = r.gradFee + r.lockerFee + r.headerlessFee;

        r.priceWeiPer1e18 = IKitchenUtils(utils).getVirtualPrice(token);
        if (s.ethPool > r.totalFee && r.priceWeiPer1e18 > 0) {
            r.ethForLP   = s.ethPool - r.totalFee;
            r.tokensToLP = (r.ethForLP * 1e18) / r.priceWeiPer1e18;
        }
        r.tokenFee = s.circulatingSupply / 100;
        uint256 mintedPortion = s.circulatingSupply + r.tokenFee + r.tokensToLP;
        r.tokensToBurn = mintedPortion < t.totalSupply ? (t.totalSupply - mintedPortion) : 0;
    }

    /* --------------------------- Admin --------------------------- */

    function syncAuthorizations() external onlyOwner {
        storageContract.authorizeCaller(address(this), true);
    }

    function updateFactory(address _factory) external onlyOwner { factory = _factory; }
    function updateLocker(address _locker) external onlyOwner { locker = _locker; }
    function updateRouter(address _router) external onlyOwner { router = _router; }
    function updateTreasury(address _treasury) external onlyOwner { steakhouseTreasury = _treasury; }
    function updateWETH(address _weth) external onlyOwner { WETH = _weth; }
    function updateStorage(address _storage) external onlyOwner { storageContract = KitchenStorage(_storage); }
    function updateKitchenBondingCurve(address _kitchenBondingCurve) external onlyOwner { kitchenBondingCurve = _kitchenBondingCurve; }
    function updateUtils(address _utils) external onlyOwner { utils = _utils; }

    // stipend setter already added above:
    // function updateStipend(uint256 newStipend) external onlyOwner { stipend = newStipend; }

    // ==============================
    // EMERGENCY
    // ==============================

    function emergencyWithdraw(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        uint256 bal = address(this).balance;
        require(amount > 0 && amount <= bal, "Invalid amount");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Withdraw failed");
    }

function getConfig() external view returns (
    address _storageContract,
    address _factory,
    address _locker,
    address _router,
    address _treasury,
    address _weth,
    address _bondingCurve,
    address _utils,
    address _owner
) {
    return (
        address(storageContract),
        factory,
        locker,
        router,
        steakhouseTreasury,
        WETH,
        kitchenBondingCurve,
        utils,
        owner
    );
}


}
