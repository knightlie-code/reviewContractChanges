// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenStorage.sol";
import "./KitchenEvents.sol";
import "./KitchenTimelock.sol";

error InsufficientETHFee();
error CurveTaxTooHigh();
error FinalTaxTooHigh();
error BasicTokenExists();
error AdvancedTokenExists();
error FinalTaxMustBeZero();

// --- Events ---
event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
event StorageUpdated(address indexed oldStorage, address indexed newStorage);
event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
event EmergencyWithdraw(address indexed to, uint256 amount);



contract KitchenCreatorBasicAdvanced is KitchenEvents, KitchenTimelock {
    KitchenStorage public storageContract;
    address public steakhouseTreasury;
    address public owner;


    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

        // --- Access Control ---
    address public factory;

    modifier onlyFactory() {
        require(msg.sender == factory, "Not factory");
        _;
    }

function setFactory(address _factory)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_FACTORY"))
{
    address old = factory;
    factory = _factory;
    emit FactoryUpdated(old, _factory);
}



    constructor(address _storage, address _treasury) {
        owner = msg.sender;
        storageContract = KitchenStorage(_storage);
        steakhouseTreasury = _treasury;
    }

    // Admin: update the canonical storage pointer (used by creators and runtime checks)
    // Note: onlyOwner; changing this moves the authoritative token metadata store.
function setStorage(address s)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_STORAGE"))
{
    address old = address(storageContract);
    storageContract = KitchenStorage(s);
    emit StorageUpdated(old, s);
}


    // Admin: update the treasury address that receives platform skim/lock fees
function setTreasury(address t)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_TREASURY"))
{
    address old = steakhouseTreasury;
    steakhouseTreasury = t;
    emit TreasuryUpdated(old, t);
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


    // Compatibility shim used by other contracts when authorizations should be re-synced.
    // Left intentionally blank in this implementation; kept for external tooling compatibility.
    function syncAuthorizations() external {}

    /* ---------------- Structs ---------------- */

    struct BasicParamsBasic {
        string name;
        string symbol;
        uint256 totalSupply;
        KitchenStorage.TokenType tokenType;
        uint256 graduationCap;
        uint256 lpLockDuration;
        bool burnLP;
        uint256 startTime;
        uint256 finalTaxRate;
        bool removeHeader;
    }

    struct BasicParamsAdvanced {
        string name;
        string symbol;
        uint256 totalSupply;
        KitchenStorage.TokenType tokenType;
        uint256 graduationCap;
        uint256 lpLockDuration;
        bool burnLP;
        uint256 startTime;
        uint256 finalTaxRate;
        bool removeHeader;
        // --- NEW MULTI-TAX WALLET SUPPORT ---
        address[4] taxWallets;  // Up to 4 dev/marketing/revshare wallets
        uint8[4]   taxSplits;   // % shares (sum = 100)
    }

    struct StaticCurveParams {
        uint256 curveStartingTax;
        uint256 curveTaxDuration;
        uint256 curveMaxWallet;
        uint256 curveMaxWalletDuration;
        uint256 curveMaxTx;
        uint256 curveMaxTxDuration;
    }

    struct AdvancedParamsInput {
        uint256 taxDropStep;
        uint256 taxDropInterval;
        uint256 maxWalletStep;
        uint256 maxWalletInterval;
        uint256 maxTxStep;
        uint256 maxTxInterval;
        uint256 limitRemovalTime;
    }

    /* ---------------- Helpers ---------------- */

function _newVirtualTokenId(address creator) internal returns (address token) {
    // use shared global nonce from KitchenStorage to avoid address collisions
    uint256 globalNonce = storageContract.incrementNonce();
    token = address(uint160(uint256(keccak256(
        abi.encodePacked(creator, globalNonce)
    ))));
}


    function _pushInitialState(address token, uint256 startTime) internal {
        KitchenStorage.TokenState memory st = KitchenStorage.TokenState({
            ethPool: 0,
            circulatingSupply: 0,
            graduated: false,
            createdAtBlock: block.number,
            createdAtTimestamp: block.timestamp,
            startTime: startTime,
            limitsStart: startTime
        });
        storageContract.setTokenState(token, st);
    }

    function _checksUnique(address token) internal view {
        if (storageContract.getTokenBasic(token).creator != address(0)) revert BasicTokenExists();
        if (storageContract.getTokenAdvanced(token).creator != address(0)) revert AdvancedTokenExists();
    }

    /* ---------------- BASIC ---------------- */

    function createBasicToken(
        BasicParamsBasic calldata b,
        StaticCurveParams calldata s,
        address creator
    ) external payable onlyFactory {
    // bounds
    if (s.curveStartingTax > 20) revert CurveTaxTooHigh();

    // final tax rules:
    // - always cap to 5% max (defense-in-depth)
    // - if final ERC20 type is NO_TAX, finalTaxRate must be exactly 0
    if (b.finalTaxRate > 5) revert FinalTaxTooHigh();
    if (b.tokenType == KitchenStorage.TokenType.NO_TAX && b.finalTaxRate != 0) revert FinalTaxMustBeZero();


        address token = _newVirtualTokenId(creator);
        _checksUnique(token);
        if (storageContract.getTokenBasic(token).creator != address(0)) revert BasicTokenExists();

        KitchenStorage.TokenBasic memory tb = KitchenStorage.TokenBasic({
            creator: creator,
            name: b.name,
            symbol: b.symbol,
            totalSupply: b.totalSupply,
            graduationCap: b.graduationCap,
            curveStartingTax: s.curveStartingTax,
            curveTaxDuration: s.curveTaxDuration,
            curveMaxWallet: s.curveMaxWallet,
            curveMaxWalletDuration: s.curveMaxWalletDuration,
            curveMaxTx: s.curveMaxTx,
            curveMaxTxDuration: s.curveMaxTxDuration,
            tokenType: b.tokenType,
            finalTaxRate: b.finalTaxRate,
            removeHeader: b.removeHeader,
            lpConfig: KitchenStorage.LPLockConfig(b.lpLockDuration, b.burnLP)
        });

    // Persist static metadata for BASIC profile and initialize runtime TokenState.
    storageContract.setTokenBasic(token, tb);
    _pushInitialState(token, b.startTime);

    }

    function createBasicTokenStealth(
        BasicParamsBasic calldata b,
        StaticCurveParams calldata s,
        address creator
    ) external payable onlyFactory {
    // stealth variants follow same validation but write to the stealth registry.
    if (s.curveStartingTax > 20) revert CurveTaxTooHigh();
    if (b.finalTaxRate > 5) revert FinalTaxTooHigh();
    if (b.tokenType == KitchenStorage.TokenType.NO_TAX && b.finalTaxRate != 0) revert FinalTaxMustBeZero();


        address token = _newVirtualTokenId(creator);
        _checksUnique(token);
        if (storageContract.getTokenBasic(token).creator != address(0)) revert BasicTokenExists();

        KitchenStorage.TokenBasic memory tb = KitchenStorage.TokenBasic({
            creator: creator,
            name: b.name,
            symbol: b.symbol,
            totalSupply: b.totalSupply,
            graduationCap: b.graduationCap,
            curveStartingTax: s.curveStartingTax,
            curveTaxDuration: s.curveTaxDuration,
            curveMaxWallet: s.curveMaxWallet,
            curveMaxWalletDuration: s.curveMaxWalletDuration,
            curveMaxTx: s.curveMaxTx,
            curveMaxTxDuration: s.curveMaxTxDuration,
            tokenType: b.tokenType,
            finalTaxRate: b.finalTaxRate,
            removeHeader: b.removeHeader,
            lpConfig: KitchenStorage.LPLockConfig(b.lpLockDuration, b.burnLP)
        });

    // store into the `basicStealth` slot: used by off-chain tooling to discover stealth launches.
    storageContract.setTokenBasicStealth(token, tb);
    _pushInitialState(token, b.startTime);
    }

    /* ---------------- ADVANCED ---------------- */

    function createAdvancedToken(
        BasicParamsAdvanced calldata b,
        StaticCurveParams calldata s,
        AdvancedParamsInput calldata a,
        address creator,
        // --- NEW MULTI-TAX WALLET SUPPORT ---
        address[4] calldata  taxWallets,  // Up to 4 dev/marketing/revshare wallets
        uint8[4] calldata   taxSplits   // % shares (sum = 100)
    ) external payable onlyFactory {
    // Advanced tokens may have time-varying tax/limits; still enforce conservative bounds here.
    if (s.curveStartingTax > 20) revert CurveTaxTooHigh();
    if (b.finalTaxRate > 5) revert FinalTaxTooHigh();
    if (b.tokenType == KitchenStorage.TokenType.NO_TAX && b.finalTaxRate != 0) revert FinalTaxMustBeZero();


        address token = _newVirtualTokenId(creator);
        _checksUnique(token);
        if (storageContract.getTokenAdvanced(token).creator != address(0)) revert AdvancedTokenExists();

        KitchenStorage.TokenAdvanced memory ta = KitchenStorage.TokenAdvanced({
            creator: creator,
            name: b.name,
            symbol: b.symbol,
            totalSupply: b.totalSupply,
            graduationCap: b.graduationCap,
            taxWallet: address(0), 
            taxWallets: taxWallets,
            taxSplits: taxSplits,
            curveStartingTax: s.curveStartingTax,
            taxDropStep: a.taxDropStep,
            taxDropInterval: a.taxDropInterval,
            maxWalletStart: s.curveMaxWallet,
            maxWalletStep: a.maxWalletStep,
            maxWalletInterval: a.maxWalletInterval,
            maxTxStart: s.curveMaxTx,
            maxTxStep: a.maxTxStep,
            maxTxInterval: a.maxTxInterval,
            limitRemovalTime: a.limitRemovalTime,
            tokenType: b.tokenType,
            finalTaxRate: b.finalTaxRate,
            removeHeader: b.removeHeader,
            lpConfig: KitchenStorage.LPLockConfig(b.lpLockDuration, b.burnLP)
        });

    // Persist ADVANCED metadata and initialize runtime state. ADVANCED contains dynamic
    // drop-step/interval parameters used by `KitchenUtils.getCurrentTax` and limits helpers.
    storageContract.setTokenAdvanced(token, ta);
    storageContract.setTokenTaxInfo(token, taxWallets, taxSplits);
    _pushInitialState(token, b.startTime);

    string memory n = b.name;
    string memory sy = b.symbol;
    uint256 ts = b.totalSupply;
    uint256 gc = b.graduationCap;

    emit TokenCreated(token, creator, uint256(b.tokenType), true, n, sy, ts, gc, s.curveStartingTax, b.finalTaxRate, s.curveMaxWallet,    // maxWallet 
    s.curveMaxTx,  gc   );
    }

    function createAdvancedTokenStealth(
        BasicParamsAdvanced calldata b,
        StaticCurveParams calldata s,
        AdvancedParamsInput calldata a,
        address creator,
        address[4] calldata taxWallets,  // Up to 4 dev/marketing/revshare wallets
        uint8[4] calldata  taxSplits   // % shares (sum = 100)
    ) external payable onlyFactory {
    // stealth variant of ADVANCED: persists to stealth storage mapping so the exposed
    // token registry does not list the launch until explicit reveal.
    if (s.curveStartingTax > 20) revert CurveTaxTooHigh();
    if (b.finalTaxRate > 5) revert FinalTaxTooHigh();
    if (b.tokenType == KitchenStorage.TokenType.NO_TAX && b.finalTaxRate != 0) revert FinalTaxMustBeZero();


        address token = _newVirtualTokenId(creator);
        _checksUnique(token);
        if (storageContract.getTokenAdvanced(token).creator != address(0)) revert AdvancedTokenExists();

        KitchenStorage.TokenAdvanced memory ta = KitchenStorage.TokenAdvanced({
            creator: creator,
            name: b.name,
            symbol: b.symbol,
            totalSupply: b.totalSupply,
            graduationCap: b.graduationCap,
            taxWallet: address(0), 
            taxWallets: taxWallets,
            taxSplits: taxSplits,
            curveStartingTax: s.curveStartingTax,
            taxDropStep: a.taxDropStep,
            taxDropInterval: a.taxDropInterval,
            maxWalletStart: s.curveMaxWallet,
            maxWalletStep: a.maxWalletStep,
            maxWalletInterval: a.maxWalletInterval,
            maxTxStart: s.curveMaxTx,
            maxTxStep: a.maxTxStep,
            maxTxInterval: a.maxTxInterval,
            limitRemovalTime: a.limitRemovalTime,
            tokenType: b.tokenType,
            finalTaxRate: b.finalTaxRate,
            removeHeader: b.removeHeader,
            lpConfig: KitchenStorage.LPLockConfig(b.lpLockDuration, b.burnLP)
        });

    storageContract.setTokenAdvancedStealth(token, ta);
    _pushInitialState(token, b.startTime);
    }

// ==========================================================
// Safety: Prevent stuck ETH 
// ==========================================================
receive() external payable {}

function withdraw(address payable to)
    external
    onlyOwner
    timelocked(keccak256("EMERGENCY_WITHDRAW"))
{
    require(to != address(0), "Zero address");
    uint256 amt = address(this).balance;
    require(amt > 0, "No balance");
    (bool ok, ) = to.call{value: amt}("");
    require(ok, "Withdraw failed");
    emit EmergencyWithdraw(to, amt);
}



}
