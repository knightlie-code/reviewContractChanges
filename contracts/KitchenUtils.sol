// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenStorage.sol";
import "./KitchenCurveMaths.sol";
import "./KitchenTimelock.sol";

interface IKitchenOracles {
    function ethUsd() external view returns (uint256 price, uint256 updatedAt);
}


contract KitchenUtils is KitchenTimelock {
    KitchenStorage public storageContract;
    address public owner;
    address public oracle;


    event StorageUpdated(address indexed oldStorage, address indexed newStorage);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _storageAddress) {
        owner = msg.sender;
        storageContract = KitchenStorage(_storageAddress);
    }

    function updateStorage(address _newStorage) external onlyOwner timelocked(keccak256("UPDATE_STORAGE")) {
        address old = address(storageContract);
        storageContract = KitchenStorage(_newStorage);
        emit StorageUpdated(old, _newStorage);
    }

function setOracle(address _oracle)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_ORACLE"))
{
    require(_oracle != address(0), "Invalid oracle");
    emit OracleUpdated(oracle, _oracle);
    oracle = _oracle;
}


    // ========= TRADE FEES (BPS) =========
    // ZeroSimple + SuperSimple => 1.0% (100 bps)
    // Basic                    => 1.0% (100 bps)
    // Advanced                 => 1.0% (100 bps)
    // ========= CONFIGURABLE TRADE FEES (BPS per type) =========
    uint256 public tradeFeeAdvanced = 100;   // 1.0%
    uint256 public tradeFeeBasic    = 100;   // 1.0%
    uint256 public tradeFeeSimple   = 100;   // 1.0%

        // ========= DYNAMIC TRADE FEE RESOLUTION =========
    function getTradeFee(address token) public view returns (uint256) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        if (p == KitchenStorage.CurveProfile.ADVANCED) return tradeFeeAdvanced;
        if (p == KitchenStorage.CurveProfile.BASIC) return tradeFeeBasic;
        return tradeFeeSimple; // SUPER_SIMPLE or ZERO_SIMPLE
    }

    event TradeFeeUpdated(string tokenType, uint256 oldValue, uint256 newValue);

    function updateTradeFeeAdvanced(uint256 newFee)
        external
        onlyOwner
        timelocked(keccak256("UPDATE_TRADE_FEE_ADVANCED"))
    {
        require(newFee <= 100, "Too high"); // ≤1%
        emit TradeFeeUpdated("ADVANCED", tradeFeeAdvanced, newFee);
        tradeFeeAdvanced = newFee;
    }

    function updateTradeFeeBasic(uint256 newFee)
        external
        onlyOwner
        timelocked(keccak256("UPDATE_TRADE_FEE_BASIC"))
    {
        require(newFee <= 100, "Too high");
        emit TradeFeeUpdated("BASIC", tradeFeeBasic, newFee);
        tradeFeeBasic = newFee;
    }

    function updateTradeFeeSimple(uint256 newFee)
        external
        onlyOwner
        timelocked(keccak256("UPDATE_TRADE_FEE_SIMPLE"))
    {
        require(newFee <= 100, "Too high");
        emit TradeFeeUpdated("SIMPLE", tradeFeeSimple, newFee);
        tradeFeeSimple = newFee;
    }


    // ========= CURVE TAX (PERCENT) =========
    // Advanced: decays but never below finalTaxRate
    // Basic: static
    // Super/Zero: 0%
    function getCurrentTax(address token) public view returns (uint256) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);

if (p == KitchenStorage.CurveProfile.ADVANCED) {
    KitchenStorage.TokenAdvanced memory a = storageContract.getTokenAdvanced(token);
    KitchenStorage.TokenState memory s = storageContract.getTokenState(token);

    // Clamp the final floor:
    // - never above 5
    // - force to 0 if graduating to NO_TAX
    uint256 ft = a.finalTaxRate;
    if (ft > 5) ft = 5;
    // NOTE: Do NOT force ft = 0 for NO_TAX tokens; they can still decay naturally to 0 during curve.
    // The graduation step will carry their finalTaxRate (0) to the real ERC20.

    if (a.taxDropInterval == 0) {
        // static starting tax but not below clamped floor
        return a.curveStartingTax < ft ? ft : a.curveStartingTax;
    }

    uint256 elapsed = block.timestamp - s.limitsStart;
    uint256 decay = (elapsed * a.taxDropStep) / a.taxDropInterval;


    if (decay >= a.curveStartingTax) return ft;
    uint256 current = a.curveStartingTax - decay;
    return current < ft ? ft : current;
}


    // BASIC profile: static startingTax that flips to finalTax after `curveTaxDuration` seconds
// BASIC profile: static startingTax that flips to finalTax after `curveTaxDuration` seconds
if (p == KitchenStorage.CurveProfile.BASIC) {
    KitchenStorage.TokenBasic memory b = storageContract.getTokenBasic(token);
    KitchenStorage.TokenState memory s = storageContract.getTokenState(token);

    // Clamp the final floor:
    // - never above 5
    // - force to 0 if graduating to NO_TAX
    uint256 ft = b.finalTaxRate;
    if (ft > 5) ft = 5;

    if (b.curveTaxDuration == 0) {
        // static starting tax but not below clamped floor
        return b.curveStartingTax < ft ? ft : b.curveStartingTax;
    }

    bool finished = block.timestamp >= s.limitsStart + b.curveTaxDuration;
    return finished ? ft : (b.curveStartingTax < ft ? ft : b.curveStartingTax);
}


        return 0; // SUPER_SIMPLE or ZERO_SIMPLE
    }

    // ========= LIMITS =========
    function isLimitsLifted(address token) public view returns (bool) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);

        if (p == KitchenStorage.CurveProfile.ADVANCED) {
            KitchenStorage.TokenAdvanced memory a = storageContract.getTokenAdvanced(token);
            KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
            return block.timestamp >= s.limitsStart + a.limitRemovalTime;
        }

        // BASIC: each limit (max wallet, max tx) has its own duration; both must have expired
        // for limits to be considered lifted.
        if (p == KitchenStorage.CurveProfile.BASIC) {
            KitchenStorage.TokenBasic memory b = storageContract.getTokenBasic(token);
            KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
            bool walletLift = (b.curveMaxWalletDuration > 0) && (block.timestamp >= s.limitsStart + b.curveMaxWalletDuration);
            bool txLift     = (b.curveMaxTxDuration > 0)     && (block.timestamp >= s.limitsStart + b.curveMaxTxDuration);
            return walletLift && txLift;
        }

        if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) {
            return false; // static
        }

        return true; // ZERO_SIMPLE (no limits)
    }

    function getCurrentMaxWallet(address token) public view returns (uint256) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);

        if (p == KitchenStorage.CurveProfile.ADVANCED) {
            KitchenStorage.TokenAdvanced memory a = storageContract.getTokenAdvanced(token);
            KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
            if (isLimitsLifted(token)) return type(uint256).max;
            if (a.maxWalletInterval == 0) return a.maxWalletStart;
            uint256 elapsed = block.timestamp - s.limitsStart;
            uint256 increment = (elapsed * a.maxWalletStep) / a.maxWalletInterval;
            return a.maxWalletStart + increment;

        }

        // BASIC: before the wallet duration expires the configured maxWallet applies,
        // afterwards the max is effectively unbounded.
        if (p == KitchenStorage.CurveProfile.BASIC) {
            KitchenStorage.TokenBasic memory b = storageContract.getTokenBasic(token);
            KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
            if (b.curveMaxWalletDuration > 0 && block.timestamp >= s.limitsStart + b.curveMaxWalletDuration)
                return type(uint256).max;
            return b.curveMaxWallet;
        }

        if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) {
            return storageContract.getTokenSuperSimple(token).maxWallet;
        }

        return type(uint256).max; // ZERO_SIMPLE
    }

    function getCurrentMaxTx(address token) public view returns (uint256) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);

        if (p == KitchenStorage.CurveProfile.ADVANCED) {
            KitchenStorage.TokenAdvanced memory a = storageContract.getTokenAdvanced(token);
            KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
            if (isLimitsLifted(token)) return type(uint256).max;
            if (a.maxTxInterval == 0) return a.maxTxStart;
            uint256 elapsed = block.timestamp - s.limitsStart;
            uint256 increment = (elapsed * a.maxTxStep) / a.maxTxInterval;
            return a.maxTxStart + increment;

        }

        // BASIC: maxTx similar to maxWallet in lifetime semantics.
        if (p == KitchenStorage.CurveProfile.BASIC) {
            KitchenStorage.TokenBasic memory b = storageContract.getTokenBasic(token);
            KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
            if (b.curveMaxTxDuration > 0 && block.timestamp >= s.limitsStart + b.curveMaxTxDuration)
                return type(uint256).max;
            return b.curveMaxTx;
        }

        if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) {
            return storageContract.getTokenSuperSimple(token).maxTx;
        }

        return type(uint256).max; // ZERO_SIMPLE
    }

    // ========= FINAL TAX (PERCENT) =========
    function getFinalTaxRate(address token) external view returns (uint256) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        if (p == KitchenStorage.CurveProfile.ADVANCED) return storageContract.getTokenAdvanced(token).finalTaxRate;
        if (p == KitchenStorage.CurveProfile.BASIC) return storageContract.getTokenBasic(token).finalTaxRate;
        if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) return storageContract.getTokenSuperSimple(token).finalTaxRate;
        return storageContract.getTokenZeroSimple(token).finalTaxRate;
    }

    // ========= VIRTUAL PRICE =========
    /// Mid price (no fees) at current pool/supply
function getVirtualPrice(address token) public view returns (uint256) {
    KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
    uint256 ts = _getTotalSupply(token);
    if (s.circulatingSupply == 0) return 0;
    // Price from genesis math (+1 ETH model), independent of transient pool state
    return KitchenCurveMaths.marginalPriceAt(ts, s.circulatingSupply);
}


    /// Marginal price at hypothetical `supply` (genesis +1 ETH model), wei per 1e18
    function virtualPriceAtSupply(address token, uint256 supply) external view returns (uint256) {
        if (supply == 0) return 0;
        uint256 ts = _getTotalSupply(token);
        return KitchenCurveMaths.marginalPriceAt(ts, supply);
    }

    // ========= CREATION-TIME HELPERS =========
    /// ETH that would be in the pool at `supply` from genesis (+1 ETH model)
    function expectedEthPoolAtSupply(address token, uint256 supply) public view returns (uint256) {
        if (supply == 0) return 0;
        uint256 ts = _getTotalSupply(token);
        return KitchenCurveMaths.ethAtSupplyFromGenesis(ts, supply);
    }

function quoteDevBuyOptions(address token)
    external
    view
    returns (uint256[5] memory ethCosts)
{
    // percentages we want: 1, 3, 5, 10, 15
    uint256[5] memory percents = [uint256(1), 3, 5, 10, 15];

    KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
    uint256 totalSupply;

    if (p == KitchenStorage.CurveProfile.ADVANCED)
        totalSupply = storageContract.getTokenAdvanced(token).totalSupply;
    else if (p == KitchenStorage.CurveProfile.BASIC)
        totalSupply = storageContract.getTokenBasic(token).totalSupply;
    else if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE)
        totalSupply = storageContract.getTokenSuperSimple(token).totalSupply;
    else
        totalSupply = storageContract.getTokenZeroSimple(token).totalSupply;

    for (uint256 i = 0; i < percents.length; i++) {
        uint256 supplyPoint = (totalSupply * percents[i]) / 100;
        ethCosts[i] = KitchenCurveMaths.ethAtSupplyFromGenesis(totalSupply, supplyPoint);
    }
    return ethCosts;
}



    // ========= QUOTES (fee-inclusive) =========
    function quoteBuy(address token, uint256 ethIn)
        external
        view
        returns (uint256 tokensOut, uint256 effectiveWeiPer1e18)
    {
        if (ethIn == 0) return (0, 0);

    // The quote mirrors the runtime path: platform fee is skimmed first (BPS), then the
    // curve tax (PERCENT) is removed from the remaining ETH. The resulting `toCurve`
    // is what the bonding curve receives and converts to tokens via the closed-form math.
    KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
    uint256 ts = _getTotalSupply(token);

    uint256 pf = (ethIn * getTradeFee(token)) / 10_000; // platform fee
    uint256 rem = ethIn - pf;

    uint256 df = (rem * getCurrentTax(token)) / 100;    // dev/tax
    uint256 toCurve = rem - df;

    tokensOut = KitchenCurveMaths.getTokensForEth(ts, s.ethPool, s.circulatingSupply, toCurve);
    effectiveWeiPer1e18 = (tokensOut == 0) ? 0 : (ethIn * 1e18) / tokensOut;
    }

    function quoteSell(address token, uint256 amount)
        external
        view
        returns (uint256 ethOutNet, uint256 effectiveWeiPer1e18)
    {
        if (amount == 0) return (0, 0);

    // Sell quote: compute gross ETH for `amount` then apply platform fee and curve tax
    KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
    uint256 ts = _getTotalSupply(token);

    uint256 gross = KitchenCurveMaths.getEthForTokens(ts, s.ethPool, s.circulatingSupply, amount);

    uint256 pf = (gross * getTradeFee(token)) / 10_000;
    uint256 rem = gross - pf;

    uint256 df = (rem * getCurrentTax(token)) / 100;
    ethOutNet = rem - df;

    effectiveWeiPer1e18 = (amount == 0) ? 0 : (ethOutNet * 1e18) / amount;
    }

    // ========= INTERNAL =========
    function _getTotalSupply(address token) internal view returns (uint256) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        if (p == KitchenStorage.CurveProfile.ADVANCED) return storageContract.getTokenAdvanced(token).totalSupply;
        if (p == KitchenStorage.CurveProfile.BASIC) return storageContract.getTokenBasic(token).totalSupply;
        if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) return storageContract.getTokenSuperSimple(token).totalSupply;
        return storageContract.getTokenZeroSimple(token).totalSupply;
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

}
