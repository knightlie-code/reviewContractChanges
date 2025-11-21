// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenStorage.sol";
import "./KitchenEvents.sol";
import "./KitchenUtils.sol";

error BasicTokenExists();
error AdvancedTokenExists();
error SuperSimpleTokenExists();
error ZeroSimpleTokenExists();
error OnlyNoTaxAllowed();
error FinalTaxMustBeZero();
error CapOutOfBounds(uint256 ethPool, uint256 min, uint256 max);

/**
 * @title KitchenCreatorSimple
 * @notice Handles creation of SuperSimple and ZeroSimple tokens.
 * - SuperSimple = no curve tax, static limits
 * - ZeroSimple  = no curve tax, no limits
 * - Both only allowed as NO_TAX final type
 */
contract KitchenCreatorSimple is KitchenEvents {
    KitchenStorage public storageContract;
    KitchenUtils public utils;
    address public steakhouseTreasury;
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _storage, address _utils, address _treasury) {
        owner = msg.sender;
        storageContract = KitchenStorage(_storage);
        utils = KitchenUtils(_utils);
        steakhouseTreasury = _treasury;
    }

    // Admin setters: change storage, utils helpers, and treasury address
    // These are privileged operations and update references used across creation and runtime helpers.
    function setStorage(address s) external onlyOwner { storageContract = KitchenStorage(s); }
    function setTreasury(address t) external onlyOwner { steakhouseTreasury = t; }
    function setUtils(address u) external onlyOwner { utils = KitchenUtils(u); }

    // No-op shim for compatibility with orchestration scripts that call `syncAuthorizations`.
    function syncAuthorizations() external {}

    // ---------------- Helpers ----------------

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
    // Ensure the token id is not already registered in any token registry.
    if (storageContract.getTokenBasic(token).creator != address(0)) revert BasicTokenExists();
    if (storageContract.getTokenAdvanced(token).creator != address(0)) revert AdvancedTokenExists();
    if (storageContract.getTokenSuperSimple(token).creator != address(0)) revert SuperSimpleTokenExists();
    if (storageContract.getTokenZeroSimple(token).creator != address(0)) revert ZeroSimpleTokenExists();
    }

    // ---------------- Super Simple ----------------
    function createSuperSimpleTokenPublic(
        KitchenStorage.TokenSuperSimple calldata meta,
        uint256 startTime,
        address creator
    ) external payable {
    // SuperSimple must be NO_TAX (no final tax) — enforced here for safety and indexer expectations.
    if (meta.tokenType != KitchenStorage.TokenType.NO_TAX) revert OnlyNoTaxAllowed();
    if (meta.finalTaxRate != 0) revert FinalTaxMustBeZero();

        address token = _newVirtualTokenId(creator);
        _checksUnique(token);

        KitchenStorage.TokenSuperSimple memory data = KitchenStorage.TokenSuperSimple({
            creator: creator,
            name: meta.name,
            symbol: meta.symbol,
            totalSupply: meta.totalSupply,
            graduationCap: meta.graduationCap,
            maxWallet: meta.maxWallet,
            maxTx: meta.maxTx,
            tokenType: meta.tokenType,
            finalTaxRate: meta.finalTaxRate,
            removeHeader: meta.removeHeader,
            lpConfig: meta.lpConfig
        });

    // persist public (non-stealth) SuperSimple metadata and initialize runtime state
    storageContract.setTokenSuperSimple(token, data);
    _pushInitialState(token, startTime);

emit TokenCreated(
    token,
    creator,
    uint256(meta.tokenType),
    false,                // isAdvanced
    meta.name,
    meta.symbol,
    meta.totalSupply,
    meta.graduationCap,
    0,                    // curveStartingTax (always 0 for SuperSimple)
    0,                    // finalTaxRate (must be 0 by validation)
    meta.maxWallet,       // maxWallet
    meta.maxTx,           // maxTx
    meta.graduationCap    // gradPoolTarget (or same as cap)
);

    }

    function createSuperSimpleTokenStealth(
        KitchenStorage.TokenSuperSimple calldata meta,
        uint256 startTime,
        address creator
    ) external payable {
    // stealth variant - useful for off-chain stealth launches. Same validation enforced.
    if (meta.tokenType != KitchenStorage.TokenType.NO_TAX) revert OnlyNoTaxAllowed();
    if (meta.finalTaxRate != 0) revert FinalTaxMustBeZero();

        address token = _newVirtualTokenId(creator);
        _checksUnique(token);

        KitchenStorage.TokenSuperSimple memory data = KitchenStorage.TokenSuperSimple({
            creator: creator,
            name: meta.name,
            symbol: meta.symbol,
            totalSupply: meta.totalSupply,
            graduationCap: meta.graduationCap,
            maxWallet: meta.maxWallet,
            maxTx: meta.maxTx,
            tokenType: meta.tokenType,
            finalTaxRate: meta.finalTaxRate,
            removeHeader: meta.removeHeader,
            lpConfig: meta.lpConfig
        });

    storageContract.setTokenSuperSimpleStealth(token, data);
    _pushInitialState(token, startTime);
    }

    // ---------------- Zero Simple ----------------
    function createZeroSimpleTokenPublic(
        KitchenStorage.TokenZeroSimple calldata meta,
        uint256 startTime,
        address creator
    ) external payable {
    // ZeroSimple: minimal creation path, enforced NO_TAX and zero final tax.
    if (meta.tokenType != KitchenStorage.TokenType.NO_TAX) revert OnlyNoTaxAllowed();
    if (meta.finalTaxRate != 0) revert FinalTaxMustBeZero();

        address token = _newVirtualTokenId(creator);
        _checksUnique(token);

        KitchenStorage.TokenZeroSimple memory data = KitchenStorage.TokenZeroSimple({
            creator: creator,
            name: meta.name,
            symbol: meta.symbol,
            totalSupply: meta.totalSupply,
            graduationCap: meta.graduationCap,
            tokenType: meta.tokenType,
            finalTaxRate: meta.finalTaxRate,
            removeHeader: meta.removeHeader,
            lpConfig: meta.lpConfig
        });

    storageContract.setTokenZeroSimple(token, data);
    _pushInitialState(token, startTime);

emit TokenCreated(
    token,
    creator,
    uint256(meta.tokenType),
    false,                // isAdvanced
    meta.name,
    meta.symbol,
    meta.totalSupply,
    meta.graduationCap,
    0,                    // curveStartingTax (no tax)
    0,                    // finalTaxRate (always 0)
    0,                    // maxWallet (no limits in ZeroSimple)
    0,                    // maxTx (no limits in ZeroSimple)
    meta.graduationCap    // gradPoolTarget
);

    }

    function createZeroSimpleTokenStealth(
        KitchenStorage.TokenZeroSimple calldata meta,
        uint256 startTime,
        address creator
    ) external payable {
    // Stealth variant for ZeroSimple
    if (meta.tokenType != KitchenStorage.TokenType.NO_TAX) revert OnlyNoTaxAllowed();
    if (meta.finalTaxRate != 0) revert FinalTaxMustBeZero();

        address token = _newVirtualTokenId(creator);
        _checksUnique(token);

        KitchenStorage.TokenZeroSimple memory data = KitchenStorage.TokenZeroSimple({
            creator: creator,
            name: meta.name,
            symbol: meta.symbol,
            totalSupply: meta.totalSupply,
            graduationCap: meta.graduationCap,
            tokenType: meta.tokenType,
            finalTaxRate: meta.finalTaxRate,
            removeHeader: meta.removeHeader,
            lpConfig: meta.lpConfig
        });

    storageContract.setTokenZeroSimpleStealth(token, data);
    _pushInitialState(token, startTime);
    }

    // ---------------- Legacy shims ----------------
    function createSuperSimpleToken(
        KitchenStorage.TokenSuperSimple calldata meta,
        uint256 startTime,
        bool isStealth,
        address creator
    ) external payable {
        if (isStealth) {
            this.createSuperSimpleTokenStealth(meta, startTime, creator);
        } else {
            this.createSuperSimpleTokenPublic(meta, startTime, creator);
        }
    }

    function createZeroSimpleToken(
        KitchenStorage.TokenZeroSimple calldata meta,
        uint256 startTime,
        bool isStealth,
        address creator
    ) external payable {
        if (isStealth) {
            this.createZeroSimpleTokenStealth(meta, startTime, creator);
        } else {
            this.createZeroSimpleTokenPublic(meta, startTime, creator);
        }
    }

    function getConfig() external view returns (
    address _storageContract,
    address _utils,
    address _treasury,
    address _owner
) {
    return (
        address(storageContract),
        address(utils),
        steakhouseTreasury,
        owner
    );
}

}
