// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title KitchenEvents
/// @notice Shared events across the entire STEAKHOUSE system (Factory, BondingCurve, Utils, etc.)
abstract contract KitchenEvents {
    // This file centralizes events used across the system. Events are intentionally
    // grouped by subsystem (Factory/Trading/Fees/etc.) so an auditor can quickly
    // find where specific system actions are emitted and traced in logs.
    // ========== FACTORY & TOKEN CREATION ==========

    /// Emitted when a new token is created on the curve
    /// @param tokenType 0 = NO_TAX, 1 = TAX
    /// @param isAdvanced true = advanced curve with decay & dynamic limits
event TokenCreated(
    address indexed token,
    address indexed creator,
    uint256 tokenType,
    bool isAdvanced,
    string name,
    string symbol,
    uint256 totalSupply,
    uint256 graduationCap,
    uint256 curveStartingTax,
    uint256 finalTaxRate,
    uint256 maxWallet,
    uint256 maxTx,
    uint256 gradPoolTarget
);


    // Emitted when a creator registers a new virtual token on the curve. Useful
    // to track creation parameters off-chain and to correlate subsequent buys.

    /// Emitted when the V2 token contract is deployed after graduation
    event TokenDeployed(
        address indexed token,
        address indexed creator,
        bool isTax,
        bool isHeaderless,
        uint256 v2TaxRate,
        bool isSuperSimple,
        bool isZeroSimple
    );

    // Fired by the Graduation controller after the real ERC20 contract is deployed.
    // Contains metadata indicating whether the deployed token uses the headerless
    // implementation and the final tax rate chosen.

    /// Emitted when a new token is fully graduated
    event TokenGraduated(
        address indexed token,
        address creator,
        uint256 finalSupply,
        uint256 ethPool,
        uint256 blockNumber,
        uint256 marketCapReached
    );

    // TokenGraduated marks a successful launch: the V2 token exists, LP was
    // created/locked/burned according to configuration, and buyers will receive
    // their V2 allotments. Auditors should correlate this with storage changes
    // in KitchenStorage (realTokenAddress, tokenLP) and with LPFinalized.

    /// Emitted after LP is created and finalized at launch
    event LPFinalized(
        address indexed token,
        address indexed locker,
        uint256 ethAdded,
        uint256 tokensAdded,
        uint256 liquidity,
        uint256 finalPriceWei,
        uint256 tokensBurned
    );

    // LPFinalized provides details of the liquidity that was added at graduation
    // including final price and tokens burned. This helps validate that the
    // graduation math matched expectations.

    /// Emitted if LP tokens are burned post-graduation
    event LPBurned(
        address indexed token,
        uint256 burnedAmount,
        uint256 timestamp
    );

    // LPBurned is emitted when liquidity is intentionally burned instead of
    // being locked; burn is permanent and indicates a different launch policy.

    /// Emitted when LP is locked to the locker contract
    event LockedLP(
        address indexed token,
        address indexed locker,
        uint256 ethAmount,
        uint256 lpTokens,
        uint256 unlockTime
    );

    // LockedLP is emitted when LP tokens are passed to the locker contract with
    // an unlock time. It includes the unlockTime so auditors can confirm lock
    // lengths and minimum duration constraints.

    /// Emitted when manual or auto graduation triggers launch
    event CurveGraduationTriggered(
        address indexed token,
        uint256 targetCap,
        uint256 blockTime
    );

    // Emitted when a graduation is requested: auto-graduation attempts inside
    // the buy path trigger this event and external owner/operator calls may also
    // trigger it (manual graduation).

    event GraduationStipendPaid(
        address indexed token, 
        address indexed buyer, 
        uint256 stipend
    );


    // ========== TRADING CURVE (BUY/SELL) ==========

    /// Emitted when a token is bought on the curve
    event Buy(
        address indexed buyer,
        address indexed token,
        uint256 ethIn,
        uint256 tokensOut,
        uint256 newBalance
    );

    // Buy and Sell are the primary on-chain trade events for the bonding curve.
    // They are emitted per trade and used extensively in analytics and gas profiling.

    /// Emitted when a token is sold on the curve
    event Sell(
        address indexed seller,
        address indexed token,
        uint256 tokensSold,
        uint256 ethOut
    );

    /// Emitted when a token's bonding curve is updated after trade
    event CurveSync(
        address indexed token,
        uint256 virtualEth,
        uint256 circulatingSupply
    );

    // CurveSync indicates that internal curve bookkeeping (ethPool / circulatingSupply)
    // was updated after a trade. Use this to validate on-chain state transitions.

    /// Emitted when manual sync is performed on a token
    event ManualSync(
        address indexed token,
        uint256 ethPool,
        uint256 supply
    );

    // ========== FEES: NEW MODEL (PLATFORM INSTANT, DEV/TAX) ==========

    /// Emitted when platform/treasury fee is transferred instantly
    event TreasuryFeePaid(
        address indexed token,
        uint256 amount
    );

    /// Emitted when a dev/tax fee is paid instantly per trade
    event DevFeePaid(
        address indexed token,
        address indexed payee,
        uint256 amount
    );

    // ========== FEES: LEGACY (DEPRECATED) ==========

    /// @dev Deprecated: we now accrue dev/tax fees instead of transferring per-tx
    event DevFeeReceived(
        address indexed token,
        address indexed feeReceiver,
        uint256 amount
    );

    /// @dev Deprecated: ambiguous in the new accrual model
    event TaxApplied(
        address indexed token,
        address indexed taxWallet,
        uint256 amount
    );

    // ========== ADVANCED DECAY (OPTIONAL/ANALYTICS) ==========

    /// Emitted as tax and limits decay across blocks (ADVANCED only)
    event AdvancedDecayProgress(
        address indexed token,
        uint256 currentTax,
        uint256 currentMaxTx,
        uint256 currentMaxWallet
    );

    // AdvancedDecayProgress is emitted as the dynamic decay model progresses for
    // ADVANCED curves. It helps auditors confirm that tax and limits are decaying
    // as expected over time.

    // ========== AIRDROP & DISTRIBUTIONS ==========

    /// Emitted when V2 tokens are airdropped to buyers
    event AirdropExecuted(
        address indexed token,
        uint256 totalRecipients,
        uint256 totalAmount,
        uint256 timestamp
    );

    // AirdropExecuted records mass distributions of V2 tokens to buyers after
    // graduation. The timestamp and totalAmount fields are useful when auditing
    // final token allocations.

    // ========== SYSTEM MGMT / UTILITIES ==========

    /// Emitted when contract owner transfers ownership
    event OwnershipTransferred(
        address indexed oldOwner,
        address indexed newOwner
    );

    // Ownership and StorageUpdated events are control-plane signals and should
    // be monitored for changes to privileged addresses.

    /// Emitted when a system component updates its storage address
    event StorageUpdated(
        address indexed oldStorage,
        address indexed newStorage
    );

        // ========== DEBUGGING / OVERSHOOT SAFEGUARDS ==========

    /// Emitted if a final buy overshoots the graduation cap but <= allowed % (10%)
    event OvershootAccepted(
        address indexed token,
        uint256 ethIn,
        uint256 allowedOvershoot,
        uint256 actualOvershoot
    );

    /// Emitted if a buy > allowed overshoot is rejected
    event OvershootRejected(
        address indexed token,
        uint256 ethIn,
        uint256 allowedOvershoot,
        uint256 actualOvershoot
    );

}
