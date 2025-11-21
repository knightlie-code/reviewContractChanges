// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenEvents.sol";
import "./KitchenCurveMaths.sol";
import "./KitchenStorage.sol";
import "./KitchenUtils.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./KitchenTimelock.sol";
import { IKitchenOracles as IKitchenOraclesBonding } from "./interfaces/IKitchenOracles.sol";



interface IKitchenGraduation {
    function graduateToken(address token, address stipendReceiver) external;
}


/**
 * @title KitchenBondingCurve
 * @notice Executes virtual token trades using bonding curve math.
 *         Auto-graduation remains unchanged.
 *
 * Changes:
 * - Dev/creator fees are PAID IMMEDIATELY on each trade (no accrual/claims).
 * - If token is TAX, 10% of the curve tax is skimmed to treasury, 90% to payee.
 * - Removed accruedEth + claimAccrued/getAccrued.
 */
contract KitchenBondingCurve is KitchenEvents, KitchenTimelock, ReentrancyGuard {
    KitchenStorage public storageContract;
    KitchenUtils public utilsContract;
    address public owner;
    address public steakhouseTreasury;
    address public graduation;

    /// @notice router that can trade on behalf of a user
    address public kitchen;

    // Emitted when a tiny sell would produce zero ETH and the user's balance is
    // consumed (dust) instead of returning funds — used to avoid splitting infinitesimal amounts.
    event DustBurn(address indexed token, address indexed user, uint256 amount);

    // Optional new events — add to KitchenEvents if you want explicit signals
    // event DevFeePaid(address indexed token, address indexed payee, uint256 amount);


    // ---------------- structs ----------------
    struct State {
        uint256 totalSupply;
        uint256 cap;
        uint256 ethPool;
        uint256 circ;
        uint256 startTime;
        bool graduated;
    }

    struct BuyLocal {
        uint256 pf;         // platform fee (ETH)
        uint256 df;         // dev/tax fee (ETH)
        uint256 poolDelta;  // ETH to pool (integral)
        uint256 tokensOut;  // tokens minted to buyer
        uint256 used;       // ETH actually consumed (pf+df+poolDelta)
    }

    struct SellLocal {
        uint256 totalSupply;
        uint256 userBal;
        uint256 grossEthOut;
        uint256 pf;
        uint256 rem;
        uint256 df;
        uint256 toSeller;
        uint256 newBal;
        uint256 newEthPool;
        uint256 newCirc;
    }

    // ---------------- auth ----------------
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    modifier onlyGraduation() {
        require(msg.sender == graduation, "Not authorized");
        _;
    }
    modifier onlyKitchen() {
        require(msg.sender == kitchen, "Not kitchen");
        _;
    }

    constructor(address _storage, address _utils, address _graduation, address _treasury) {
        owner = msg.sender;
        storageContract = KitchenStorage(_storage);
        utilsContract = KitchenUtils(_utils);
        graduation = _graduation;
        steakhouseTreasury = _treasury;
    }

    // ---------------- admin ----------------
    function syncAuthorizations() external onlyOwner timelocked(keccak256("SYNC_AUTHORIZATIONS")) {
        storageContract.authorizeCaller(address(this), true);
    }
    function updateStorage(address s) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { storageContract = KitchenStorage(s); }
    function updateUtils(address u) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { utilsContract = KitchenUtils(u); }
    function updateGraduation(address g) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { graduation = g; }
    function updateTreasury(address t) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { steakhouseTreasury = t; }
    function setKitchen(address _kitchen) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { kitchen = _kitchen; }

// === Stipend configuration ===
uint256 public stipendBase = 0.003 ether; // floor
uint256 public stipendHardCap = 0.15 ether;
uint256 public stipendSafetyNum = 150; // 150%
uint256 public stipendSafetyDen = 100;

// --- Oracle freshness windows ---
uint256 public constant ORACLE_MAX_AGE = 10_800;    // 3 hours for ETH/USD
uint256 public constant GAS_ORACLE_MAX_AGE = 900;   // 15 minutes for gas price

// Gas tiers based on measured graduation gas ranges
uint256 public gasUnitsTier1 = 5_000_000;  // ≤50 holders
uint256 public gasUnitsTier2 = 7_000_000;  // 51–100
uint256 public gasUnitsTier3 = 11_000_000; // 101–200
uint256 public gasUnitsTier4 = 16_000_000; // 201–300

event StipendBaseUpdated(uint256 oldValue, uint256 newValue);
event StipendGasUnitsUpdated(uint256 t1, uint256 t2, uint256 t3, uint256 t4);
event StipendSafetyUpdated(uint256 num, uint256 den);
event StipendHardCapUpdated(uint256 oldValue, uint256 newValue);

function updateStipendBase(uint256 newBase)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_STIPEND_BASE"))
{
    require(newBase > 0 && newBase <= 0.05 ether, "Invalid base");
    emit StipendBaseUpdated(stipendBase, newBase);
    stipendBase = newBase;
}

function updateStipendGasUnits(uint256 t1, uint256 t2, uint256 t3, uint256 t4)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_STIPEND_GASUNITS"))
{
    require(t1 > 0 && t2 >= t1 && t3 >= t2 && t4 >= t3, "bad tiers");
    gasUnitsTier1 = t1;
    gasUnitsTier2 = t2;
    gasUnitsTier3 = t3;
    gasUnitsTier4 = t4;
    emit StipendGasUnitsUpdated(t1, t2, t3, t4);
}

function updateStipendSafety(uint256 num, uint256 den)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_STIPEND_SAFETY"))
{
    require(num >= 100 && num <= 300 && den >= 100, "bad safety");
    stipendSafetyNum = num;
    stipendSafetyDen = den;
    emit StipendSafetyUpdated(num, den);
}

function updateStipendHardCap(uint256 newCap)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_STIPEND_CAP"))
{
    require(newCap >= stipendBase && newCap <= 0.1 ether, "bad cap");
    emit StipendHardCapUpdated(stipendHardCap, newCap);
    stipendHardCap = newCap;
}



event TreasuryCutUpdated(uint256 oldValue, uint256 newValue);

function updateTreasuryCut(uint256 newCut)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_TREASURY_CUT"))
{
    require(newCut <= 2500, "Too high"); // ≤25%
    emit TreasuryCutUpdated(storageContract.treasuryCutBps(), newCut);
    storageContract.setTreasuryCutBps(newCut);
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


    // ==============================
    // ENTRYPOINTS
    // ==============================
    function buyToken(address token) external payable nonReentrant  {
        _buy(token, msg.sender, msg.value);
    }
    function buyTokenFor(address token, address buyer) external payable nonReentrant  onlyKitchen {
        _buy(token, buyer, msg.value);
    }
    function sellToken(address token, uint256 amt) external nonReentrant {
        _sell(token, msg.sender, amt);
    }
    function sellTokenFor(address token, address seller, uint256 amt) external nonReentrant onlyKitchen {
        _sell(token, seller, amt);
    }

// ---- NEW: slippage-protected paths (optional to use; legacy still works) ----
function buyTokenWithMinOut(address token, uint256 minTokensOut) external payable nonReentrant  {
    _buyWithMinOut(token, msg.sender, msg.value, minTokensOut);
}
function buyTokenForWithMinOut(address token, address buyer, uint256 minTokensOut) external payable nonReentrant  onlyKitchen {
    _buyWithMinOut(token, buyer, msg.value, minTokensOut);
}
function sellTokenWithMinOut(address token, uint256 amt, uint256 minEthOut) external nonReentrant {
    _sellWithMinOut(token, msg.sender, amt, minEthOut);
}
function sellTokenForWithMinOut(address token, address seller, uint256 amt, uint256 minEthOut) external nonReentrant onlyKitchen {
    _sellWithMinOut(token, seller, amt, minEthOut);
}

    // ==============================
    // CORE LOGIC
    // ==============================
    function _loadState(address token) internal view returns (State memory st) {
        KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
        st.startTime = s.startTime;
        st.graduated = s.graduated;
        st.ethPool   = s.ethPool;
        st.circ      = s.circulatingSupply;
        st.totalSupply = _getTotalSupply(token);
        st.cap         = _getGraduationCap(token);
    }

    function _feesFor(uint256 amount, uint256 feeBps, uint256 devPerc)
        internal pure returns (uint256 pf, uint256 df, uint256 toCurve)
    {
        pf = (amount * feeBps) / 10_000;
        uint256 rem = amount - pf;
        df = (rem * devPerc) / 100;
        toCurve = rem - df;
    }

    function _computeBuyOutcome(State memory st, uint256 ethIn, uint256 feeBps, uint256 devPerc)
        internal pure returns (BuyLocal memory L)
    {
        (L.pf, L.df, L.poolDelta) = _feesFor(ethIn, feeBps, devPerc);
        L.tokensOut = KitchenCurveMaths.getTokensForEth(
            st.totalSupply, st.ethPool, st.circ, L.poolDelta
        );
        L.used = L.pf + L.df + L.poolDelta;
    }

function _buy(address token, address buyer, uint256 ethIn) internal {
    // Backward-compatible path: no slippage check
    _buyWithMinOut(token, buyer, ethIn, 0);
}

function _buyWithMinOut(address token, address buyer, uint256 ethIn, uint256 minTokensOut) internal {
    require(ethIn > 0, "ETH=0");

    State memory st = _loadState(token);
    require(block.timestamp >= st.startTime, "Token not live");
    require(!st.graduated, "Token graduated");
    require(st.circ < st.cap, "Cap reached");

    uint256 feeBps  = _getTradeFeeBps(token);
    uint256 devPerc = _getCurrentDevTaxPercent(token);

    // Compute fees + intended poolDelta
    BuyLocal memory L = _computeBuyOutcome(st, ethIn, feeBps, devPerc);

    // Tokens out based purely on curve maths (no ETH cap logic)
    L.tokensOut = KitchenCurveMaths.getTokensForEth(
        st.totalSupply, st.ethPool, st.circ, L.poolDelta
    );

    require(L.tokensOut > 0, "Zero tokens");
    if (minTokensOut > 0) {
        require(L.tokensOut >= minTokensOut, "Slippage: tokensOut < min");
    }

    // --- MAXTX / MAXWALLET with 6s CREATOR EXEMPTION ---
    (address creator, uint256 exemptUntil) = storageContract.getCreatorExemptInfo(token);
    uint256 userBalance = storageContract.userBalances(buyer, token);

    if (!(buyer == creator && block.timestamp <= exemptUntil)) {
        require(L.tokensOut <= utilsContract.getCurrentMaxTx(token), "Exceeds maxTx");
        require(userBalance + L.tokensOut <= utilsContract.getCurrentMaxWallet(token), "Exceeds maxWallet");
    }

    // Commit new state
    uint256 newEthPool = st.ethPool + L.poolDelta;
    uint256 newCirc    = st.circ + L.tokensOut;
    storageContract.updateTokenState(token, newEthPool, newCirc);

    // Update balances
    if (userBalance == 0) storageContract.addBuyer(token, buyer);
    storageContract.updateUserBalance(buyer, token, userBalance + L.tokensOut);

    // Wallet analytics
    storageContract.incrementWalletBuyVolumeByToken(buyer, token, L.used);

    // Global analytics
    storageContract.incrementTokenVolume(token, L.used);
    storageContract.incrementTradeCount(token);

    // === Fee flows ===
    if (L.pf > 0) {
        (bool okPf, ) = payable(steakhouseTreasury).call{value: L.pf}("");
        require(okPf, "Treasury fee");
        emit TreasuryFeePaid(token, L.pf);
    }

    if (L.df > 0) {
        address payee = _getTaxReceiver(token);
        (uint256 toTreasury, uint256 toPayee) = _splitTaxForToken(token, L.df);

        if (toTreasury > 0) {
            (bool okSkim, ) = payable(steakhouseTreasury).call{value: toTreasury}("");
            require(okSkim, "Treasury skim");
        }
        if (toPayee > 0) {
            (bool okDev, ) = payable(payee).call{value: toPayee}("");
            require(okDev, "Dev fee");
            storageContract.incrementDevEarnings(token, toPayee + toTreasury);
        } else {
            storageContract.incrementDevEarnings(token, toTreasury);
        }
    }

    // Final refund (safe, after all updates & fees)
    if (ethIn > L.used) {
        (bool okRf, ) = payable(buyer).call{value: ethIn - L.used}("");
        require(okRf, "Refund failed");
    }

    emit Buy(buyer, token, L.used, L.tokensOut, userBalance + L.tokensOut);
    emit CurveSync(token, newEthPool, newCirc);

    // Auto-graduation purely by token cap + overshoot tolerance
    uint256 overshootCap = st.cap + (st.cap * storageContract.overshootBps()) / 10_000;
    if (newCirc >= st.cap) {
        require(newCirc <= overshootCap, "Exceeds overshoot limit");
        IKitchenGraduation(graduation).graduateToken(token, buyer);
    }
}


function _sell(address token, address seller, uint256 amt) internal {
    // Backward-compatible path: no slippage check
    _sellWithMinOut(token, seller, amt, 0);
}

function _sellWithMinOut(address token, address seller, uint256 amt, uint256 minEthOut) internal {
    require(amt > 0, "Amount>0");

    KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
    require(block.timestamp >= s.startTime, "Token not live");
    require(!s.graduated, "Token graduated");

    SellLocal memory L;
    L.totalSupply = _getTotalSupply(token);

    L.userBal = storageContract.userBalances(seller, token);
    require(L.userBal >= amt, "Insufficient balance");

    // maxTx for sells
    {
        uint256 maxTx = utilsContract.getCurrentMaxTx(token);
        require(amt <= maxTx, "Exceeds maxTx");
    }

    // Quote ETH out (gross)
    L.grossEthOut = KitchenCurveMaths.getEthForTokens(
        L.totalSupply, s.ethPool, s.circulatingSupply, amt
    );

    // ---- Dust path ----
    if (L.grossEthOut == 0) {
        require(amt == L.userBal, "Dust amount; sell full balance");
        uint256 newCircDust = s.circulatingSupply - amt;

        storageContract.updateTokenState(token, s.ethPool, newCircDust);
        storageContract.updateUserBalance(seller, token, 0);
        storageContract.removeBuyer(token, seller);

        storageContract.incrementTradeCount(token);

        emit DustBurn(token, seller, amt);
        emit CurveSync(token, s.ethPool, newCircDust);
        return;
    }

    // Platform fee, dev fee, net to seller
    L.pf = (L.grossEthOut * _getTradeFeeBps(token)) / 10_000;
    L.rem = L.grossEthOut - L.pf;

    storageContract.incrementTokenVolume(token, L.grossEthOut);
    storageContract.incrementTradeCount(token);

    if (L.pf > 0) {
        (bool okPf, ) = payable(steakhouseTreasury).call{value: L.pf}("");
        require(okPf, "Treasury fee");
        emit TreasuryFeePaid(token, L.pf);
    }

    L.df = (L.rem * _getCurrentDevTaxPercent(token)) / 100;
    L.toSeller = L.rem - L.df;

    // NEW: slippage check (min ETH out)
    if (minEthOut > 0) {
        require(L.toSeller >= minEthOut, "Slippage: ethOut < min");
    }

    if (L.df > 0) {
        address payee = _getTaxReceiver(token);
        (uint256 toTreasury, uint256 toPayee) = _splitTaxForToken(token, L.df);

        if (toTreasury > 0) {
            (bool okSkim, ) = payable(steakhouseTreasury).call{value: toTreasury}("");
            require(okSkim, "Treasury skim");
        }
        if (toPayee > 0) {
            (bool okDev, ) = payable(payee).call{value: toPayee}("");
            require(okDev, "Dev fee");
            storageContract.incrementDevEarnings(token, toPayee + toTreasury);
        } else {
            storageContract.incrementDevEarnings(token, toTreasury);
        }
    }

    // New state
    L.newBal     = L.userBal - amt;
    L.newEthPool = s.ethPool - L.grossEthOut; // pool loses full gross
    L.newCirc    = s.circulatingSupply - amt;

    // Commit
    storageContract.updateTokenState(token, L.newEthPool, L.newCirc);
    storageContract.updateUserBalance(seller, token, L.newBal);
    if (L.newBal == 0) storageContract.removeBuyer(token, seller);

    // wallet analytics
    storageContract.incrementWalletSellVolumeByToken(seller, token, L.toSeller);

    emit Sell(seller, token, amt, L.toSeller);
    emit CurveSync(token, L.newEthPool, L.newCirc);

    (bool ok, ) = payable(seller).call{value: L.toSeller}("");
    require(ok, "ETH xfer");
}


    // ==============================
    // GRADUATION ETH RELEASE
    // ==============================
    function releaseGraduationETH(address token, address receiver, uint256 amount)
        external
        onlyGraduation
        nonReentrant
    {
        require(receiver == graduation, "Receiver must be Graduation");

        KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
        require(amount <= s.ethPool, "Over-withdraw");

        storageContract.updateTokenState(token, s.ethPool - amount, s.circulatingSupply);

        (bool ok, ) = payable(receiver).call{value: amount}("");
        require(ok, "ETH send failed");
    }

    // ==============================
    // HELPERS
    // ==============================
    function _getTradeFeeBps(address token) internal view returns (uint256) {
        return utilsContract.getTradeFee(token);
    }
    function _getCurrentDevTaxPercent(address token) internal view returns (uint256) {
        return utilsContract.getCurrentTax(token);
    }
    function _getTaxReceiver(address token) internal view returns (address) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        if (p == KitchenStorage.CurveProfile.ADVANCED) {
            return storageContract.getTokenAdvanced(token).taxWallet;
        }
        return storageContract.getTokenBasic(token).creator != address(0)
            ? storageContract.getTokenBasic(token).creator
            : storageContract.getTokenSuperSimple(token).creator != address(0)
                ? storageContract.getTokenSuperSimple(token).creator
                : storageContract.getTokenZeroSimple(token).creator;
    }
    function _getTotalSupply(address token) internal view returns (uint256) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        if (p == KitchenStorage.CurveProfile.ADVANCED) return storageContract.getTokenAdvanced(token).totalSupply;
        if (p == KitchenStorage.CurveProfile.BASIC) return storageContract.getTokenBasic(token).totalSupply;
        if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) return storageContract.getTokenSuperSimple(token).totalSupply;
        return storageContract.getTokenZeroSimple(token).totalSupply;
    }
    function _getGraduationCap(address token) internal view returns (uint256) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        if (p == KitchenStorage.CurveProfile.ADVANCED) return storageContract.getTokenAdvanced(token).graduationCap;
        if (p == KitchenStorage.CurveProfile.BASIC) return storageContract.getTokenBasic(token).graduationCap;
        if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) return storageContract.getTokenSuperSimple(token).graduationCap;
        return storageContract.getTokenZeroSimple(token).graduationCap;
    }

    function _isTaxToken(address token) internal view returns (bool) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        if (p == KitchenStorage.CurveProfile.ADVANCED) return storageContract.getTokenAdvanced(token).tokenType == KitchenStorage.TokenType.TAX;
        if (p == KitchenStorage.CurveProfile.BASIC)    return storageContract.getTokenBasic(token).tokenType == KitchenStorage.TokenType.TAX;
        if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) return storageContract.getTokenSuperSimple(token).tokenType == KitchenStorage.TokenType.TAX;
        return storageContract.getTokenZeroSimple(token).tokenType == KitchenStorage.TokenType.TAX;
    }

function _readEthUsdPrice(address oracleAddr) internal view returns (uint256 price, uint256 updatedAt) {
    if (oracleAddr == address(0)) return (0, 0);
    (bool ok, bytes memory data) = oracleAddr.staticcall(
        abi.encodeWithSignature("ethUsd()")
    );
    if (ok && data.length >= 64) {
        (price, updatedAt) = abi.decode(data, (uint256, uint256));
    }
}


function _gasPriceWei() internal view returns (uint256) {
    // fallback
    uint256 baseFee = block.basefee;
    uint256 gasPrice = baseFee < 1 gwei ? 1 gwei : baseFee;

    // get oracle address from utils
    address oracleAddr;
    try utilsContract.oracle() returns (address addr) {
        oracleAddr = addr;
    } catch {
        oracleAddr = address(0);
    }

if (oracleAddr != address(0)) {
    // encode selector for gasWei()
    (bool ok, bytes memory data) = oracleAddr.staticcall(
        abi.encodeWithSignature("gasWei()")
    );

    if (ok && data.length >= 64) {
        (uint256 price, uint256 updatedAt) = abi.decode(data, (uint256, uint256));
        // Only accept fresh gas price; otherwise keep fallback (basefee or 1 gwei)
        if (price > 0 && updatedAt != 0 && block.timestamp - updatedAt <= GAS_ORACLE_MAX_AGE) {
            gasPrice = price;
        }
    }
}


    return gasPrice;
}





function _gasUnitsForHolders(uint256 holderCount) internal view returns (uint256) {
    if (holderCount <= 50) return gasUnitsTier1;
    if (holderCount <= 100) return gasUnitsTier2;
    if (holderCount <= 200) return gasUnitsTier3;
    return gasUnitsTier4;
}


/// @dev returns (toTreasury, toPayee)
function _splitTaxForToken(address token, uint256 df) internal view returns (uint256, uint256) {
    if (df == 0) return (0, 0);
    if (_isTaxToken(token)) {
        uint256 bps = storageContract.treasuryCutBps();           // e.g. 1000 = 10%
        uint256 toTreasury = (df * bps) / 10_000;                  // dynamic skim
        if (toTreasury > df) toTreasury = df;                      // safety (shouldn’t happen)
        return (toTreasury, df - toTreasury);
    } else {
        return (0, df);
    }
}


function getDynamicStipend(uint256 holderCount) public view returns (uint256) {
    uint256 gasUnits = _gasUnitsForHolders(holderCount);
    uint256 gasWei = _gasPriceWei();

    // raw = gasUnits * gasWei
    uint256 raw = gasUnits * gasWei;
    uint256 padded = (raw * stipendSafetyNum) / stipendSafetyDen;

    if (padded < stipendBase) padded = stipendBase;
    if (padded > stipendHardCap) padded = stipendHardCap;

    return padded;
}



    function getConfig() external view returns (
        address _storageContract,
        address _utilsContract,
        address _graduation,
        address _treasury,
        address _kitchen,
        address _owner
    ) {
        return (
            address(storageContract),
            address(utilsContract),
            address(graduation),
            steakhouseTreasury,
            kitchen,
            owner
        );
    }

    receive() external payable {}
}
