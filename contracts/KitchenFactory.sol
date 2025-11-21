// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenStorage.sol";
import "./KitchenEvents.sol";
import { KitchenCreatorBasicAdvanced as KC_BA } from "./KitchenCreatorBasicAdvanced.sol";
import { KitchenCreatorSimple as KC_Simple } from "./KitchenCreatorSimple.sol";
import "./KitchenTimelock.sol";

/// Interfaces for the split modules
interface IKitchenCreatorBasicAdvanced {
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
        address[4] taxWallets;  // Up to 4 wallets
        uint8[4]   taxSplits;   // Percentages (sum = 100)
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

    function createBasicToken(
        BasicParamsBasic calldata b,
        StaticCurveParams calldata s,
        address creator
    ) external payable;

    function createBasicTokenStealth(
        BasicParamsBasic calldata b,
        StaticCurveParams calldata s,
        address creator
    ) external payable;

    function createAdvancedToken(
        BasicParamsAdvanced calldata b,
        StaticCurveParams calldata s,
        AdvancedParamsInput calldata a,
        address creator,
        address[4] calldata taxWallets,
        uint8[4] calldata taxSplits
    ) external payable;

    function createAdvancedTokenStealth(
        BasicParamsAdvanced calldata b,
        StaticCurveParams calldata s,
        AdvancedParamsInput calldata a,
        address creator,
        address[4] calldata taxWallets,
        uint8[4] calldata taxSplits
    ) external payable;

    function syncAuthorizations() external;
}

interface IKitchenCreatorSimpleSplit {
    function createSuperSimpleToken(
        KitchenStorage.TokenSuperSimple calldata meta,
        uint256 startTime,
        bool isStealth,
        address creator
    ) external payable;

    function createZeroSimpleToken(
        KitchenStorage.TokenZeroSimple calldata meta,
        uint256 startTime,
        bool isStealth,
        address creator
    ) external payable;

    function syncAuthorizations() external;
}

interface IKitchenDeployer {
    function deployToken(
        string memory name,
        string memory symbol,
        address creator,
        address taxWallet,
        bool isTax,
        bool removeHeader,
        uint256 finalTaxRate,
        uint256 maxSupply
    ) external payable returns (address tokenAddress);

    function mintRealToken(address token, address to, uint256 amount) external;
}


/// Errors
error NotOwner();
error NotGraduationOrCurve();
error OnlyCurve();
error OnlyGraduation();
error HeaderFlagNotCreator();
error CapOutOfBounds(uint256 ethAtCap, uint256 minEthAtCap, uint256 maxEthAtCap);
error BadCap(uint256 graduationCap, uint256 totalSupply);
error InsufficientCreationFee(uint256 required, uint256 provided);

/**
 * @title KitchenFactory (Thin Dispatcher)
 */
contract KitchenFactory is KitchenEvents, KitchenTimelock {
uint256 public BASE_FEE_BASIC       = 0.003 ether;
uint256 public BASE_FEE_ADVANCED    = 0.006 ether;
uint256 public BASE_FEE_SUPERSIMPLE = 0.001 ether;
uint256 public BASE_FEE_ZEROSIMPLE  = 0.0005 ether;

uint256 public HEADERLESS_FEE = 0.001 ether;
uint256 public STEALTH_FEE    = 0.003 ether;

event CreationFeesUpdated(uint256 BASIC, uint256 ADVANCED, uint256 SUPERSIMPLE, uint256 ZEROSIMPLE);
event ModeFeesUpdated(uint256 HEADERLESS, uint256 STEALTH);

function updateCreationFees(
    uint256 _BASIC,
    uint256 _ADVANCED,
    uint256 _SUPERSIMPLE,
    uint256 _ZEROSIMPLE
) external onlyOwner timelocked(keccak256("UPDATE_FEES")) {
    BASE_FEE_BASIC       = _BASIC;
    BASE_FEE_ADVANCED    = _ADVANCED;
    BASE_FEE_SUPERSIMPLE = _SUPERSIMPLE;
    BASE_FEE_ZEROSIMPLE  = _ZEROSIMPLE;
    emit CreationFeesUpdated(_BASIC, _ADVANCED, _SUPERSIMPLE, _ZEROSIMPLE);
}

function updateModeFees(uint256 _HEADERLESS, uint256 _STEALTH)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_FEES"))
{
    HEADERLESS_FEE = _HEADERLESS;
    STEALTH_FEE    = _STEALTH;
    emit ModeFeesUpdated(_HEADERLESS, _STEALTH);
}


    // Core state
    KitchenStorage public storageContract;
    address public bondingCurve;
    address public router;
    address public owner;
    address public steakhouseTreasury;
    address public kitchen;
    address public graduation;
    address public utils;


    // Modules
    IKitchenCreatorBasicAdvanced public creatorBA;
    IKitchenCreatorSimpleSplit   public creatorSimple;
    IKitchenDeployer             public deployer;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyGraduation() {
        if (msg.sender != graduation) revert NotGraduationOrCurve();
        _;
    }

    constructor(
        address _bondingCurve,
        address _router,
        address _storage,
        address _utils,
        address _treasury
    ) {
        owner = msg.sender;
        bondingCurve = _bondingCurve;
        router = _router;
        storageContract = KitchenStorage(_storage);
        steakhouseTreasury = _treasury;
        utils = _utils;
    }

        // ------------------------------------------------------------
    // Anti-PVP name/ticker tracking (72h cooldown)
    // ------------------------------------------------------------
    uint256 public antiPvpCooldown = 3 days;

    event AntiPvpCooldownUpdated(uint256 newCooldown);

    function setAntiPvpCooldown(uint256 newCooldown) external onlyOwner timelocked(keccak256("UPDATE_ANTIPVP"))  {
        require(newCooldown >= 1 days && newCooldown <= 7 days, "Invalid cooldown");
        antiPvpCooldown = newCooldown;
        emit AntiPvpCooldownUpdated(newCooldown);
    }

// ---------------- wiring ----------------
function setCreatorBasicAdvanced(address a) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) {
    creatorBA = IKitchenCreatorBasicAdvanced(a);
    // removed internal .setFactory() call
}

function setCreatorSimple(address a) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) {
    creatorSimple = IKitchenCreatorSimpleSplit(a);
    // removed internal .setFactory() call
}



    function setDeployer(address a) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { deployer = IKitchenDeployer(a); }

    function setBondingCurve(address a) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { bondingCurve = a; }
    function setRouter(address a) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { router = a; }
    function setStorageContract(address a) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { storageContract = KitchenStorage(a); }
    function setTreasury(address a) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { steakhouseTreasury = a; }
    function setKitchen(address a) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { kitchen = a; }
    function setGraduation(address a) external onlyOwner timelocked(keccak256("UPDATE_MODULES")) { graduation = a; }

    // ---------------- auth sync ----------------
    function syncAuthorizations() external onlyOwner timelocked(keccak256("SYNC_AUTHORIZATIONS")) {
    // Authorize core modules in the storage contract. Called once after
    // deployment/wiring to grant modules write access to storage.
    storageContract.authorizeModule(address(this));
        if (address(creatorBA) != address(0)) storageContract.authorizeModule(address(creatorBA));
        if (address(creatorSimple) != address(0)) storageContract.authorizeModule(address(creatorSimple));
        if (bondingCurve != address(0)) storageContract.authorizeModule(bondingCurve);
        if (kitchen != address(0)) storageContract.authorizeModule(kitchen);
        if (graduation != address(0)) storageContract.authorizeModule(graduation);
        if (address(creatorBA) != address(0)) creatorBA.syncAuthorizations();
        if (address(creatorSimple) != address(0)) creatorSimple.syncAuthorizations();
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

    // ---------------- helpers ----------------

function _normalize(string memory str) internal pure returns (string memory) {
    bytes memory b = bytes(str);
    for (uint256 i = 0; i < b.length; i++) {
        if (b[i] >= 0x41 && b[i] <= 0x5A) {
            b[i] = bytes1(uint8(b[i]) + 32); // uppercase → lowercase
        }
    }
    return string(b);
}

mapping(bytes32 => uint256) private _lastLaunchTimestamp;

function _checkAndRecordName(string memory name, string memory symbol) internal {
    bytes32 key = keccak256(abi.encodePacked(_normalize(name), _normalize(symbol)));
    uint256 last = _lastLaunchTimestamp[key];
    require(
        last == 0 || block.timestamp >= last + antiPvpCooldown,
        "PVP: Name/symbol combo in cooldown"
    );
    _lastLaunchTimestamp[key] = block.timestamp;
}

    function _collectFees(uint256 baseFee, bool removeHeader, bool isStealth) internal returns (uint256 remaining) {
        uint256 required = baseFee;
        if (removeHeader) required += HEADERLESS_FEE;
        if (isStealth) required += STEALTH_FEE;

        if (msg.value < required) revert InsufficientCreationFee(required, msg.value);

    // Forward required fees to the treasury and return any leftover ETH that
    // should be forwarded to creator modules (creatorBA / creatorSimple).
    (bool ok,) = payable(steakhouseTreasury).call{value: required}("");
    require(ok, "Treasury fee fail");

    return msg.value - required;
    }


// ---------------- create flows ----------------
function createBasicToken(
    IKitchenCreatorBasicAdvanced.BasicParamsBasic calldata b,
    IKitchenCreatorBasicAdvanced.StaticCurveParams calldata s,
    address creator
) external payable {
    _checkAndRecordName(b.name, b.symbol);
    if (b.graduationCap == 0) revert BadCap(b.graduationCap, b.totalSupply);

    uint256 forward = _collectFees(BASE_FEE_BASIC, b.removeHeader, false);
    creatorBA.createBasicToken{value: forward}(b, s, creator);
}

function createBasicTokenStealth(
    IKitchenCreatorBasicAdvanced.BasicParamsBasic calldata b,
    IKitchenCreatorBasicAdvanced.StaticCurveParams calldata s,
    address creator
) external payable {
    _checkAndRecordName(b.name, b.symbol);
    if (b.graduationCap == 0) revert BadCap(b.graduationCap, b.totalSupply);

    uint256 forward = _collectFees(BASE_FEE_BASIC, b.removeHeader, true);
    creatorBA.createBasicTokenStealth{value: forward}(b, s, creator);
}



function createAdvancedToken(
    IKitchenCreatorBasicAdvanced.BasicParamsAdvanced calldata b,
    IKitchenCreatorBasicAdvanced.StaticCurveParams calldata s,
    IKitchenCreatorBasicAdvanced.AdvancedParamsInput calldata a,
    address creator,
    address[4] calldata taxWallets,
    uint8[4] calldata taxSplits
) external payable {
    _checkAndRecordName(b.name, b.symbol);
    if (b.graduationCap == 0) revert BadCap(b.graduationCap, b.totalSupply);

    uint256 forward = _collectFees(BASE_FEE_ADVANCED, b.removeHeader, false);
    creatorBA.createAdvancedToken{value: forward}(b, s, a, creator, taxWallets, taxSplits);

}



function createAdvancedTokenStealth(
    IKitchenCreatorBasicAdvanced.BasicParamsAdvanced calldata b,
    IKitchenCreatorBasicAdvanced.StaticCurveParams calldata s,
    IKitchenCreatorBasicAdvanced.AdvancedParamsInput calldata a,
    address creator,
    address[4] calldata taxWallets,
    uint8[4] calldata taxSplits
) external payable {
    _checkAndRecordName(b.name, b.symbol);
    if (b.graduationCap == 0) revert BadCap(b.graduationCap, b.totalSupply);

    uint256 forward = _collectFees(BASE_FEE_ADVANCED, b.removeHeader, true);
    creatorBA.createAdvancedTokenStealth{value: forward}(b, s, a, creator, taxWallets, taxSplits);

}



function createSuperSimpleToken(
    KitchenStorage.TokenSuperSimple calldata meta,
    uint256 startTime,
    bool isStealth,
    address creator
) external payable {
    _checkAndRecordName(meta.name, meta.symbol);
    if (meta.graduationCap == 0) revert BadCap(meta.graduationCap, meta.totalSupply);

    uint256 forward = _collectFees(BASE_FEE_SUPERSIMPLE, meta.removeHeader, isStealth);
    creatorSimple.createSuperSimpleToken{value: forward}(meta, startTime, isStealth, creator);


}



function createZeroSimpleToken(
    KitchenStorage.TokenZeroSimple calldata meta,
    uint256 startTime,
    bool isStealth,
    address creator
) external payable {
    _checkAndRecordName(meta.name, meta.symbol);
    if (meta.graduationCap == 0) revert BadCap(meta.graduationCap, meta.totalSupply);

    uint256 forward = _collectFees(BASE_FEE_ZEROSIMPLE, meta.removeHeader, isStealth);
    creatorSimple.createZeroSimpleToken{value: forward}(meta, startTime, isStealth, creator);


}



    // ---------------- deploy/mint ----------------
    function deployToken(
        string memory name,
        string memory symbol,
        address creator,
        address taxWallet,
        bool isTax,
        bool removeHeader,
        uint256 finalTaxRate,
        uint256 maxSupply
    ) external payable returns (address tokenAddress) {
        if (msg.sender != graduation) revert OnlyGraduation();
        return deployer.deployToken{value: msg.value}(name, symbol, creator, taxWallet, isTax, removeHeader, finalTaxRate, maxSupply);
    }

    function mintRealToken(address token, address to, uint256 amount) external onlyGraduation {
        deployer.mintRealToken(token, to, amount);
    }

    // ---------------- views ----------------
    function getDeployedTokens() external view returns (address[] memory) {
        return storageContract.getDeployedTokens();
    }

function getConfig() external view returns (
    address _bondingCurve,
    address _router,
    address _storageContract,
    address _utils,
    address _treasury,
    address _creatorBA,
    address _creatorSimple,
    address _deployer,
    address _graduation,
    address _kitchen,
    address _owner
) {
    return (
        bondingCurve,
        router,
        address(storageContract),
        utils,
        steakhouseTreasury,
        address(creatorBA),
        address(creatorSimple),
        address(deployer),
        graduation,
        kitchen,
        owner
    );
}


}
