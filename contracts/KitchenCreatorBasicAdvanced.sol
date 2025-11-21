// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenStorage.sol";
import "./KitchenEvents.sol";

error InsufficientETHFee();
error CurveTaxTooHigh();
error FinalTaxTooHigh();
error BasicTokenExists();
error AdvancedTokenExists();

contract KitchenCreatorBasicAdvanced is KitchenEvents {
    KitchenStorage public storageContract;
    address public steakhouseTreasury;
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _storage, address _treasury) {
        owner = msg.sender;
        storageContract = KitchenStorage(_storage);
        steakhouseTreasury = _treasury;
    }

    // Admin: update the canonical storage pointer (used by creators and runtime checks)
    // Note: onlyOwner; changing this moves the authoritative token metadata store.
    function setStorage(address s) external onlyOwner { storageContract = KitchenStorage(s); }

    // Admin: update the treasury address that receives platform skim/lock fees
    function setTreasury(address t) external onlyOwner { steakhouseTreasury = t; }

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
            startTime: startTime
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
    ) external payable {
    // Validate conservative bounds: starting tax should not exceed 20%.
    if (s.curveStartingTax > 20) revert CurveTaxTooHigh();
    // If a TAX token is requested, final tax must be <= 5% (protocol-enforced cap)
    if (b.tokenType == KitchenStorage.TokenType.TAX && b.finalTaxRate > 5) revert FinalTaxTooHigh();

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

    // Emit creation event: includes minimal metadata used by off-chain indexers.
    string memory n = b.name;
    string memory sy = b.symbol;
    uint256 ts = b.totalSupply;
    uint256 gc = b.graduationCap;

    emit TokenCreated(token, creator, uint256(b.tokenType), false, n, sy, ts, gc, s.curveStartingTax, b.finalTaxRate, s.curveMaxWallet,    // maxWallet 
    s.curveMaxTx,  gc   );
    }

    function createBasicTokenStealth(
        BasicParamsBasic calldata b,
        StaticCurveParams calldata s,
        address creator
    ) external payable {
    // stealth variants follow same validation but write to the stealth registry.
    if (s.curveStartingTax > 20) revert CurveTaxTooHigh();
    if (b.tokenType == KitchenStorage.TokenType.TAX && b.finalTaxRate > 5) revert FinalTaxTooHigh();

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
        address taxWallet
    ) external payable {
    // Advanced tokens may have time-varying tax/limits; still enforce conservative bounds here.
    if (s.curveStartingTax > 20) revert CurveTaxTooHigh();
    if (b.tokenType == KitchenStorage.TokenType.TAX && b.finalTaxRate > 5) revert FinalTaxTooHigh();

        address token = _newVirtualTokenId(creator);
        _checksUnique(token);
        if (storageContract.getTokenAdvanced(token).creator != address(0)) revert AdvancedTokenExists();

        KitchenStorage.TokenAdvanced memory ta = KitchenStorage.TokenAdvanced({
            creator: creator,
            name: b.name,
            symbol: b.symbol,
            totalSupply: b.totalSupply,
            graduationCap: b.graduationCap,
            taxWallet: taxWallet,
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
        address taxWallet
    ) external payable {
    // stealth variant of ADVANCED: persists to stealth storage mapping so the exposed
    // token registry does not list the launch until explicit reveal.
    if (s.curveStartingTax > 20) revert CurveTaxTooHigh();
    if (b.tokenType == KitchenStorage.TokenType.TAX && b.finalTaxRate > 5) revert FinalTaxTooHigh();

        address token = _newVirtualTokenId(creator);
        _checksUnique(token);
        if (storageContract.getTokenAdvanced(token).creator != address(0)) revert AdvancedTokenExists();

        KitchenStorage.TokenAdvanced memory ta = KitchenStorage.TokenAdvanced({
            creator: creator,
            name: b.name,
            symbol: b.symbol,
            totalSupply: b.totalSupply,
            graduationCap: b.graduationCap,
            taxWallet: taxWallet,
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
    
}
