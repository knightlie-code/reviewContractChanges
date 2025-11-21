// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenStorage.sol";
import "./KitchenCurveMaths.sol";

contract KitchenUtils {
    KitchenStorage public storageContract;
    address public owner;

    event StorageUpdated(address indexed oldStorage, address indexed newStorage);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _storageAddress) {
        owner = msg.sender;
        storageContract = KitchenStorage(_storageAddress);
    }

    function updateStorage(address _newStorage) external onlyOwner {
        address old = address(storageContract);
        storageContract = KitchenStorage(_newStorage);
        emit StorageUpdated(old, _newStorage);
    }

    // ========= TRADE FEES (BPS) =========
    // ZeroSimple + SuperSimple => 1.0% (100 bps)
    // Basic                    => 1.0% (100 bps)
    // Advanced                 => 1.0% (100 bps)
    function getTradeFee(address token) public view returns (uint256) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        if (p == KitchenStorage.CurveProfile.ADVANCED) return 100;
        if (p == KitchenStorage.CurveProfile.BASIC) return 100;
        return 100; // SUPER_SIMPLE or ZERO_SIMPLE
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

            if (a.taxDropInterval == 0) return a.curveStartingTax;

            uint256 steps = (block.timestamp - s.createdAtTimestamp) / a.taxDropInterval;
            uint256 decay = steps * a.taxDropStep;

            if (decay >= a.curveStartingTax) return a.finalTaxRate;
            uint256 current = a.curveStartingTax - decay;
            return current < a.finalTaxRate ? a.finalTaxRate : current;
        }

    // BASIC profile: static startingTax that flips to finalTax after `curveTaxDuration` seconds
    if (p == KitchenStorage.CurveProfile.BASIC) {
        KitchenStorage.TokenBasic memory b = storageContract.getTokenBasic(token);
        KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
        if (b.curveTaxDuration == 0) return b.curveStartingTax;
        bool finished = block.timestamp >= s.createdAtTimestamp + b.curveTaxDuration;
        return finished ? b.finalTaxRate : b.curveStartingTax;
        }

        return 0; // SUPER_SIMPLE or ZERO_SIMPLE
    }

    // ========= LIMITS =========
    function isLimitsLifted(address token) public view returns (bool) {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);

        if (p == KitchenStorage.CurveProfile.ADVANCED) {
            KitchenStorage.TokenAdvanced memory a = storageContract.getTokenAdvanced(token);
            KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
            return block.timestamp >= s.createdAtTimestamp + a.limitRemovalTime;
        }

        // BASIC: each limit (max wallet, max tx) has its own duration; both must have expired
        // for limits to be considered lifted.
        if (p == KitchenStorage.CurveProfile.BASIC) {
            KitchenStorage.TokenBasic memory b = storageContract.getTokenBasic(token);
            KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
            bool walletLift = (b.curveMaxWalletDuration > 0) && (block.timestamp >= s.createdAtTimestamp + b.curveMaxWalletDuration);
            bool txLift     = (b.curveMaxTxDuration > 0)     && (block.timestamp >= s.createdAtTimestamp + b.curveMaxTxDuration);
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
            uint256 steps = (block.timestamp - s.createdAtTimestamp) / a.maxWalletInterval;
            return a.maxWalletStart + (steps * a.maxWalletStep);
        }

        // BASIC: before the wallet duration expires the configured maxWallet applies,
        // afterwards the max is effectively unbounded.
        if (p == KitchenStorage.CurveProfile.BASIC) {
            KitchenStorage.TokenBasic memory b = storageContract.getTokenBasic(token);
            KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
            if (b.curveMaxWalletDuration > 0 && block.timestamp >= s.createdAtTimestamp + b.curveMaxWalletDuration)
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
            uint256 steps = (block.timestamp - s.createdAtTimestamp) / a.maxTxInterval;
            return a.maxTxStart + (steps * a.maxTxStep);
        }

        // BASIC: maxTx similar to maxWallet in lifetime semantics.
        if (p == KitchenStorage.CurveProfile.BASIC) {
            KitchenStorage.TokenBasic memory b = storageContract.getTokenBasic(token);
            KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
            if (b.curveMaxTxDuration > 0 && block.timestamp >= s.createdAtTimestamp + b.curveMaxTxDuration)
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

    /// Quick access to global bounds
    function getGraduationBounds() external view returns (uint256 minEthAtCap, uint256 maxEthAtCap, uint256 overshootBps) {
        minEthAtCap = storageContract.minEthAtCap();
        maxEthAtCap = storageContract.maxEthAtCap();
        overshootBps = storageContract.overshootBps();
    }

    /// Check current pool is within configured bounds
    function isPoolWithinGraduationBounds(address token) external view returns (bool) {
        KitchenStorage.TokenState memory s = storageContract.getTokenState(token);
        return s.ethPool >= storageContract.minEthAtCap() && s.ethPool <= storageContract.maxEthAtCap();
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
}
