// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenStorage.sol";
import "./KitchenEvents.sol";
import "./KitchenCurveMaths.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./KitchenTimelock.sol";

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

    function swapExactETHForTokens(
    uint amountOutMin,
    address[] calldata path,
    address to,
    uint deadline
) external payable returns (uint[] memory amounts);

}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
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

contract KitchenGraduation is KitchenEvents, KitchenTimelock {
    using SafeERC20 for IERC20;
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
        // HEADERLESS_FEE removed – fee is now charged exclusively at creation time.

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
    uint256 finalPrice;   // wei per 1e18 tokens
    uint256 ethForLP;     // total ETH budgeted for LP (pool - fees)
    uint256 ethForBuyback; // portion of ethForLP we cannot pair (auto buy+burn)
}


    /* ----------------------------- External ----------------------------- */

    // Public entrypoint to request graduation. Typically called by the
    // bonding curve (auto-graduation) or by an owner/operator script. The
    // `buyer` parameter is used to optionally refund the graduation stipend.
function graduateToken(address token, address stipendReceiver) external nonReentrant {
    _graduate(token, false, stipendReceiver);
}

    /* ------------------------------ Internal ----------------------------- */

function _graduate(address token, bool bypassCap, address stipendReceiver) internal {
    // === Read current state ===
    KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
    if (s.graduated) revert AlreadyGraduated();

    KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
    TokenMeta memory t = _readMeta(token, p);
    bool isTax = (t.tokenType == KitchenStorage.TokenType.TAX);
    bool removeHeader = _resolveRemoveHeader(token, p);

    emit GradDebugStart(token, p, s.ethPool, s.circulatingSupply, t.graduationCap, isTax, removeHeader);

    // === Bounds and validation ===
    if (!bypassCap && s.circulatingSupply < t.graduationCap)
        revert CapNotReached(s.circulatingSupply, t.graduationCap);
    if (t.finalTaxRate > 5) revert FinalTaxTooHigh(t.finalTaxRate);


    // === Fee + LP math ===
    GradParams memory g = _computeGradParams(token, t, s);
    emit GradDebugMath(
        token, g.graduationFee, g.lockerFee, g.totalFee,
        g.finalPrice, g.ethForLP, g.tokensToLP, g.tokenFee, g.tokensToBurn
    );

    // === Holder count + stipend ===
    uint256 holderCount = storageContract.getBuyerCount(token);
    uint256 dynamicStipend = IKitchenBondingCurve(kitchenBondingCurve).getDynamicStipend(holderCount);
    bool enableClaim = holderCount > 300;

    // === Pull ETH ===
    _pullFromCurve(token, s.ethPool, g.totalFee + g.ethForLP + dynamicStipend);

    // === Deploy real ERC20 ===
    address realToken = _deployRealToken(t, isTax, removeHeader, g.headerlessFee);

    // === Mint logic ===
    if (enableClaim) {
        // Claim mode: mint full circulating supply to Graduation for later claiming
        IKitchenFactory(factory).mintRealToken(realToken, address(this), s.circulatingSupply);
        storageContract.setClaimMode(token, true);
        emit GradDebugPostRelease(token, s.circulatingSupply); // reuse debug event for tracking
    } else {
        // Normal mode: direct airdrop to all holders
        _airdropBuyers(token, realToken);
    }

    // === Pay platform fee + mint treasury cut ===
    _payGradFee(g.graduationFee);
    IKitchenFactory(factory).mintRealToken(realToken, steakhouseTreasury, g.tokenFee);

    // === Add liquidity ===
    (address lpToken, uint256 liquidity) =
        _addLiquidityAndHandleLP(realToken, t.lpConfig, g.ethForLP, g.tokensToLP, t.creator, g.lockerFee);

    // === Optional: buy & burn with leftover ETH ===
    uint256 burnedFromBuyback = 0;
    if (g.ethForBuyback > 0) {
        burnedFromBuyback = _autoBuyAndBurn(realToken, g.ethForBuyback);
        storageContract.recordPostGradBuyback(token, g.ethForBuyback, burnedFromBuyback);
    }

    // === Burn any remaining supply ===
    if (g.tokensToBurn > 0) {
        IKitchenFactory(factory).mintRealToken(realToken, DEAD, g.tokensToBurn);
    }

    // === Persist state ===
    KitchenStorage.TokenState memory s2 = storageContract.getTokenState(token);
    s2.graduated = true;
    storageContract.setTokenState(token, s2);
    storageContract.markTokenGraduated(token);
    storageContract.setTokenLP(token, lpToken);
    storageContract.setRealTokenAddress(token, realToken);

    // Keep buyers list only if claim-mode; otherwise clear it
    if (!enableClaim) {
        storageContract.clearBuyers(token);
    }

    // === Stipend to last buyer ===
    if (stipendReceiver != address(0) && dynamicStipend > 0 && address(this).balance >= dynamicStipend) {
        (bool ok, ) = payable(stipendReceiver).call{value: dynamicStipend}("");
        require(ok, "Gas refund xfer failed");
        emit GraduationStipendPaid(token, stipendReceiver, dynamicStipend);
    }

    emit TokenGraduated(token, t.creator, s.circulatingSupply, g.ethForLP, block.number, t.graduationCap);
    emit LPFinalized(realToken, locker, g.ethForLP, g.tokensToLP, liquidity, g.finalPrice, g.tokensToBurn);
}

function _computeGradParams(
    address token,
    TokenMeta memory t,
    KitchenStorage.TokenState memory s
) private view returns (GradParams memory g) {
    // fees (can be later made configurable)
    g.graduationFee = 0.1 ether;
    g.lockerFee     = t.lpConfig.burnLP ? 0 : 0.08 ether;
    g.headerlessFee = 0; // no longer charged at graduation
    g.totalFee      = g.graduationFee + g.lockerFee;

    if (s.ethPool < g.totalFee) revert FeesExceedPool(s.ethPool, g.totalFee);

    // token fee to treasury (1% of circ on curve)
    g.tokenFee   = s.circulatingSupply / 100;

    // price at cap (marginal curve price)
    g.finalPrice = IKitchenUtils(utils).getVirtualPrice(token);
    if (g.finalPrice == 0) revert PriceIsZero();

    // All remaining pool ETH goes to LP *budget* initially
    g.ethForLP = s.ethPool - g.totalFee;
    if (g.ethForLP == 0) revert NoEthLeftForLP(s.ethPool, g.totalFee);

    // tokens to pair with ETH at that price
    uint256 desiredTokensToLP = (g.ethForLP * 1e18) / g.finalPrice;

    // ensure we never exceed max mintable: totalSupply - circ - tokenFee
    uint256 capRemaining;
    unchecked {
        capRemaining = t.totalSupply - s.circulatingSupply - g.tokenFee;
    }

    if (desiredTokensToLP <= capRemaining) {
        // plenty of token headroom: no buyback needed
        g.tokensToLP    = desiredTokensToLP;
        g.ethForBuyback = 0;
    } else {
        // token headroom is the limit: cap tokens, reduce ETH into LP to match exact price,
        // and push the leftover ETH into an immediate buy+burn
        g.tokensToLP = capRemaining;

        // ETH actually usable for LP at exact price with capped tokens
        uint256 ethUsableForLP = (g.tokensToLP * g.finalPrice) / 1e18;

        // split: LP gets only what keeps price exact, leftover buys & burns
        g.ethForBuyback = g.ethForLP - ethUsableForLP;
        g.ethForLP      = ethUsableForLP;
    }

    // Mint & burn the remaining supply (book-keeping) — unchanged behavior
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
    uint256 /*headerlessFee*/
) private returns (address realToken) {
    require(t.totalSupply > 0, "Invalid totalSupply");

    // Factory now handles headerless logic; no fee is paid here.
    realToken = IKitchenFactory(factory).deployToken(
        t.name,
        t.symbol,
        t.creator,
        t.taxWallet,
        isTax,
        removeHeader,
        t.finalTaxRate,
        t.totalSupply
    );
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
    // Mint tokens for LP seeding
    IKitchenFactory(factory).mintRealToken(realToken, address(this), tokensForLP);

    // Use SafeERC20 for approvals (handles non-standard tokens)
    IERC20(realToken).safeApprove(router, 0);
    IERC20(realToken).safeApprove(router, tokensForLP);

    // Capture all return values explicitly
    (uint256 usedTokens, uint256 usedEth, uint256 mintedLiquidity) =
        IUniswapV2Router02(router).addLiquidityETH{value: ethForLP}(
            realToken,
            tokensForLP,
            0,
            0,
            address(this),
            block.timestamp
        );

    // store for later return
    liquidity = mintedLiquidity;

    // Sanity check that at least some liquidity was minted
    require(liquidity > 0, "No liquidity minted");

    lpToken = IUniswapV2Factory(IUniswapV2Router02(router).factory())
        .getPair(realToken, WETH);
    require(lpToken != address(0), "LP pair missing");

    if (lp.burnLP) {
        IERC20(lpToken).safeTransfer(DEAD, liquidity);
        emit LPBurned(realToken, liquidity, block.timestamp);
    } else {
        IERC20(lpToken).safeApprove(locker, 0);
        IERC20(lpToken).safeApprove(locker, liquidity);
        ISteakLockers(locker).lock{value: lockerFee}(
            lpToken,
            liquidity,
            lp.lpLockDuration,
            creator
        );
        emit LockedLP(
            realToken,
            locker,
            usedEth,
            liquidity,
            block.timestamp + lp.lpLockDuration
        );
    }
}


// ------------------------------------------------------------
// Internal: Auto-buy and burn leftover ETH after LP seeding
// ------------------------------------------------------------
function _autoBuyAndBurn(address realToken, uint256 ethToSpend) private returns (uint256 tokensBurned) {
    require(ethToSpend > 0, "No ETH for buyback");

    // Build the swap path WETH -> realToken
    address[] memory path = new address[](2);
    path[0] = WETH;
    path[1] = realToken;

    uint256 beforeBal = IERC20(realToken).balanceOf(address(this));

    // Perform the buy — allow slippage/tax (minOut = 0)
    IUniswapV2Router02(router).swapExactETHForTokens{value: ethToSpend}(
        0,
        path,
        address(this),
        block.timestamp
    );

    uint256 bought = IERC20(realToken).balanceOf(address(this)) - beforeBal;

    // Immediately burn everything bought
    if (bought > 0) {
        IERC20(realToken).safeTransfer(DEAD, bought);
    }

    return bought;
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
        r.headerlessFee = 0; // charged only at creation time
        r.totalFee      = r.gradFee + r.lockerFee;

        r.priceWeiPer1e18 = IKitchenUtils(utils).getVirtualPrice(token);
        if (s.ethPool > r.totalFee && r.priceWeiPer1e18 > 0) {
            r.ethForLP   = s.ethPool - r.totalFee;
            r.tokensToLP = (r.ethForLP * 1e18) / r.priceWeiPer1e18;
        }
        r.tokenFee = s.circulatingSupply / 100;
        uint256 mintedPortion = s.circulatingSupply + r.tokenFee + r.tokensToLP;
        r.tokensToBurn = mintedPortion < t.totalSupply ? (t.totalSupply - mintedPortion) : 0;
    }

    /* --------------------------- Claim-Mode Functions --------------------------- */

    event TokensClaimed(address indexed token, address indexed user, uint256 amount);
    event ForcedClaim(address indexed token, address indexed user, uint256 amount);
    event RemainingDistributed(address indexed token, uint256 totalUsers, uint256 totalSent);

    /// @notice Called by individual holders to claim their graduated ERC-20 tokens.
    function claimTokens(address virtualToken) external nonReentrant {
        // Verify claim-mode active
        require(storageContract.isClaimMode(virtualToken), "Claim mode off");

        address realToken = storageContract.realTokenAddress(virtualToken);
        require(realToken != address(0), "No real token");

        // Ensure user has not already claimed
        require(!storageContract.hasClaimed(virtualToken, msg.sender), "Already claimed");

        uint256 owed = storageContract.getUserBalance(msg.sender, virtualToken);
        require(owed > 0, "Nothing to claim");

        // Mark claimed & transfer
        storageContract.setHasClaimed(virtualToken, msg.sender, true);
        IERC20(realToken).safeTransfer(msg.sender, owed);

        emit TokensClaimed(virtualToken, msg.sender, owed);
    }

    /// @notice Admin/owner helper: claim on behalf of a user (used by Steakhouse automated scripts)
    function claimForUser(address virtualToken, address user) external onlyOwner nonReentrant {
        require(storageContract.isClaimMode(virtualToken), "Claim mode off");
        address realToken = storageContract.realTokenAddress(virtualToken);
        require(realToken != address(0), "No real token");
        if (storageContract.hasClaimed(virtualToken, user)) return;

        uint256 owed = storageContract.getUserBalance(user, virtualToken);
        if (owed == 0) return;

        storageContract.setHasClaimed(virtualToken, user, true);
        IERC20(realToken).safeTransfer(user, owed);

        emit ForcedClaim(virtualToken, user, owed);
    }

    /// @notice Emergency sweep: distribute all remaining unclaimed tokens in batches.
    function distributeRemaining(address virtualToken, uint256 maxBatch) external onlyOwner nonReentrant {
        require(storageContract.isClaimMode(virtualToken), "Claim mode off");
        address realToken = storageContract.realTokenAddress(virtualToken);
        require(realToken != address(0), "No real token");

        address[] memory buyers = storageContract.getBuyers(virtualToken);
        uint256 len = buyers.length;
        uint256 cursor = storageContract.getClaimCursor(virtualToken);

        uint256 sent = 0;
        uint256 processed = 0;

        for (uint256 i = cursor; i < len && processed < maxBatch; i++) {
            address u = buyers[i];
            if (!storageContract.hasClaimed(virtualToken, u)) {
                uint256 amt = storageContract.getUserBalance(u, virtualToken);
                if (amt > 0) {
                    storageContract.setHasClaimed(virtualToken, u, true);
                    IERC20(realToken).safeTransfer(u, amt);
                    sent += amt;
                }
            }
            processed++;
        }

        // Update cursor
        storageContract.setClaimCursor(virtualToken, cursor + processed);
        emit RemainingDistributed(virtualToken, processed, sent);
    }

    /* --------------------------- Admin --------------------------- */

    function syncAuthorizations() external onlyOwner timelocked(keccak256("SYNC_AUTHORIZATIONS")) {
        storageContract.authorizeCaller(address(this), true);
    }

    function updateFactory(address _factory) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) {
        factory = _factory;
    }

    function updateLocker(address _locker) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) {
        locker = _locker;
    }

    function updateRouter(address _router) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) {
        router = _router;
    }

    function updateTreasury(address _treasury) external onlyOwner timelocked(keccak256("UPDATE_TREASURY")) {
        steakhouseTreasury = _treasury;
    }

    function updateWETH(address _weth) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) {
        WETH = _weth;
    }

    function updateStorage(address _storage) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) {
        storageContract = KitchenStorage(_storage);
    }

    function updateKitchenBondingCurve(address _kitchenBondingCurve) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) {
        kitchenBondingCurve = _kitchenBondingCurve;
    }

    function updateUtils(address _utils) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) {
        utils = _utils;
    }

function transferOwnership(address newOwner)
    external
    onlyOwner
    timelocked(keccak256("TRANSFER_OWNERSHIP"))
{
    require(newOwner != address(0), "Zero address");
    address old = owner;
    owner = newOwner;
    emit OwnershipTransferred(old, newOwner);
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
