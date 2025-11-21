// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenStorage.sol";
import "./KitchenEvents.sol";
import "./KitchenTimelock.sol";
import "./vendor/chainlink/AggregatorV3Interface.sol";
import "./KitchenCurveMaths.sol"; 



interface IKitchenFactory {
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

    function createBasicToken(
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

    function createBasicTokenStealth(
        BasicParamsBasic calldata b,
        StaticCurveParams calldata s,
        address creator
    ) external payable;

    function createAdvancedTokenStealth(
        BasicParamsAdvanced calldata b,
        StaticCurveParams calldata s,
        AdvancedParamsInput calldata a,
        address creator,
        address[4] calldata taxWallets,
        uint8[4] calldata taxSplits
    ) external payable;

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

    function deployToken(
        string memory name,
        string memory symbol,
        address creator,
        bool isTax,
        bool removeHeader,
        uint256 finalTaxRate,
        uint256 maxSupply
    ) external payable returns (address);
}

/* ---------------- Curve-Based Deployer (Headered/Headerless) ---------------- */
interface IKitchenDeployer {
    function deployToken(
        string memory name,
        string memory symbol,
        address creator,
        bool isTax,
        bool removeHeader,
        uint256 finalTaxRate,
        uint256 maxSupply
    ) external payable returns (address);

    function mintRealToken(address token, address to, uint256 amount) external;
}

/* ---------------- Direct Launcher (Manual + Stealth) ---------------- */
interface IKitchenDirectLauncher {
    struct DecayConfig {
        uint64 startTax;
        uint64 finalTax;
        uint64 decayStep;
        uint256 decayInterval;
    }

    struct LimitsConfig {
        uint128 startMaxTx;
        uint128 maxTxStep;
        uint128 startMaxWallet;
        uint128 maxWalletStep;
    }

    function deployDirectLaunchManual(
        string memory name,
        string memory symbol,
        uint256 supply,
        address taxWallet,
        address creator,
        DecayConfig memory d,
        LimitsConfig memory l
    ) external returns (address);

    function deployDirectLaunchStealth(
        string memory name,
        string memory symbol,
        uint256 supply,
        address taxWallet,
        uint256 lpPercent,
        address creator,
        DecayConfig memory d,
        LimitsConfig memory l
    ) external payable returns (address);
}

interface IKitchenBondingCurve {
    function buyTokenFor(address token, address buyer) external payable;
    function sellTokenFor(address token, address seller, uint256 amount) external;

    // --- NEW: slippage-protected paths ---
    function buyTokenForWithMinOut(address token, address buyer, uint256 minTokensOut) external payable;
    function sellTokenForWithMinOut(address token, address seller, uint256 amount, uint256 minEthOut) external;
}

interface IKitchenGraduation {
    function graduateToken(address token, address stipendReceiver) external;
}
/* ---------------- Chainlink Oracle Wrapper ---------------- */
interface IKitchenOracles {
    function ethUsd() external view returns (uint256 price, uint256 updatedAt);
}

/// @title Kitchen Router
contract Kitchen is KitchenEvents, KitchenTimelock {
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    IKitchenFactory public factory;
    IKitchenBondingCurve public kitchenBondingCurve;
    IKitchenGraduation public graduation;
    KitchenStorage public storageContract;

    IKitchenDeployer public deployer;            // curve-based deployer
    IKitchenOracles public oracle; // Chainlink-based oracle adapter



// --- Governance Events ---
event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
event BondingCurveUpdated(address indexed oldBondingCurve, address indexed newBondingCurve);
event GraduationUpdated(address indexed oldGraduation, address indexed newGraduation);
event DeployerUpdated(address indexed oldDeployer, address indexed newDeployer);
event EmergencyWithdraw(address indexed to, uint256 amount);


    // ---- validation constants ----
uint256 private constant MIN_SUPPLY = 1e18; // 1 token (18dp)
uint256 private constant MAX_SUPPLY = 1_000_000_000_000 * 1e18; // 1T tokens

uint256 private constant MW_DIVISOR = 2000;   // 0.05% = 1/2000
uint256 private constant MT_DIVISOR = 10000;  // 0.01% = 1/10000

function _validateVirtualParams(
    uint256 totalSupply,
    uint256 curveMaxWallet,
    uint256 curveMaxTx
) internal pure {
    require(totalSupply > MIN_SUPPLY && totalSupply <= MAX_SUPPLY, "Invalid supply");
    require(curveMaxWallet >= totalSupply / MW_DIVISOR, "maxWallet too small");
    require(curveMaxTx >= totalSupply / MT_DIVISOR, "maxTx too small");
}
    
function _validateGradCapUSDRange(
    uint256 totalSupply,
    uint256 graduationCap,
    uint256 ethPool
) internal view {
    require(graduationCap > 0 && graduationCap < totalSupply, "Invalid gradCap");

    // 1. Get Chainlink ETH/USD price
    (uint256 ethUsdPrice, uint256 updatedAt) = oracle.ethUsd();
    require(ethUsdPrice > 0 && block.timestamp - updatedAt <= 10_800, "Oracle stale");

    // 2. Pull min/max USD caps from storage
    (, , uint256 capMinUsd, uint256 capMaxUsd, ) = storageContract.getConfig();

    // 3. Estimate ETH in pool at graduation using virtual bonding curve maths
    uint256 ethAtCap = KitchenCurveMaths.getEthForTokens(
        totalSupply,
        ethPool,
        0,                // start circ (0 for genesis)
        graduationCap
    );

    // 4. Convert ETH value → USD (8 decimals oracle)
    uint256 usdCap = (ethAtCap * ethUsdPrice) / 1e8;

    // 5. Enforce bounds
    require(usdCap >= capMinUsd && usdCap <= capMaxUsd, "Graduation cap out of USD bounds");
}

    constructor(
        address _factory,
        address _kitchenBondingCurve,
        address _graduation,
        address _storage,
        address _deployer
        
    ) {
        owner = msg.sender;
        factory = IKitchenFactory(_factory);
        kitchenBondingCurve = IKitchenBondingCurve(_kitchenBondingCurve);
        graduation = IKitchenGraduation(_graduation);
        storageContract = KitchenStorage(_storage);
        deployer = IKitchenDeployer(_deployer);
        
    }

    // ---------- AUTH ----------
    function authorizeAllModules() public onlyOwner {
        storageContract.authorizeCaller(address(this), true);
        storageContract.authorizeCaller(address(factory), true);
        storageContract.authorizeCaller(address(kitchenBondingCurve), true);
        storageContract.authorizeCaller(address(graduation), true);
    }

    // ---------- ADMIN SETTERS ----------
function setFactory(address _factory)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_FACTORY"))
{
    address old = address(factory);
    factory = IKitchenFactory(_factory);
    emit FactoryUpdated(old, _factory);
}

function setKitchenBondingCurve(address _kitchenBondingCurve)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_BONDING_CURVE"))
{
    address old = address(kitchenBondingCurve);
    kitchenBondingCurve = IKitchenBondingCurve(_kitchenBondingCurve);
    emit BondingCurveUpdated(old, _kitchenBondingCurve);
}

function setGraduation(address _graduation)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_GRADUATION"))
{
    address old = address(graduation);
    graduation = IKitchenGraduation(_graduation);
    emit GraduationUpdated(old, _graduation);
}

function setStorage(address _storage)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_STORAGE"))
{
    address old = address(storageContract);
    storageContract = KitchenStorage(_storage);
    emit StorageUpdated(old, _storage);
}

function setDeployer(address _deployer)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_DEPLOYER"))
{
    address old = address(deployer);
    deployer = IKitchenDeployer(_deployer);
    emit DeployerUpdated(old, _deployer);
}

event OracleUpdated(address indexed oldOracle, address indexed newOracle);

function setOracle(address _oracle)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_ORACLE"))
{
    require(_oracle != address(0), "Invalid oracle");
    emit OracleUpdated(address(oracle), _oracle);
    oracle = IKitchenOracles(_oracle);
}

function transferOwnership(address newOwner)
    external
    onlyOwner
    timelocked(keccak256("TRANSFER_OWNERSHIP"))
{
    address old = owner;
    owner = newOwner;
    emit OwnershipTransferred(old, newOwner);
}


// ---------- TOKEN CREATION (Curve-based) ----------
function createBasicToken(
    IKitchenFactory.BasicParamsBasic calldata b,
    IKitchenFactory.StaticCurveParams calldata s
) external payable {
    _validateVirtualParams(b.totalSupply, s.curveMaxWallet, s.curveMaxTx);
    // --- Validate graduationCap is within bounds 36k - 500k USD->ETH->TOKEN---
    _validateGradCapUSDRange(b.totalSupply, b.graduationCap, 0);
    // --- Validate graduationCap in token units ---
    require(b.graduationCap > 0 && b.graduationCap <= b.totalSupply, "Invalid graduation cap");

    // --- Deploy token (old logic style, no assignment) ---
    factory.createBasicToken{value: msg.value}(b, s, msg.sender);

}


function createBasicTokenStealth(
    IKitchenFactory.BasicParamsBasic calldata b,
    IKitchenFactory.StaticCurveParams calldata s
) external payable {
    _validateVirtualParams(b.totalSupply, s.curveMaxWallet, s.curveMaxTx);
    // --- Validate graduationCap is within bounds 36k - 500k USD->ETH->TOKEN---
    _validateGradCapUSDRange(b.totalSupply, b.graduationCap, 0);
    // --- Validate graduationCap in token units ---
    require(b.graduationCap > 0 && b.graduationCap <= b.totalSupply, "Invalid graduation cap");

    factory.createBasicTokenStealth{value: msg.value}(b, s, msg.sender);
}


function createAdvancedToken(
    IKitchenFactory.BasicParamsAdvanced calldata b,
    IKitchenFactory.StaticCurveParams calldata s,
    IKitchenFactory.AdvancedParamsInput calldata a,
    address[4] calldata taxWallets,
    uint8[4] calldata taxSplits
) external payable {
    _validateVirtualParams(b.totalSupply, s.curveMaxWallet, s.curveMaxTx);
    // --- Validate graduationCap is within bounds 36k - 500k USD->ETH->TOKEN---
    _validateGradCapUSDRange(b.totalSupply, b.graduationCap, 0);
    // --- Validate graduationCap in token units ---
    require(b.graduationCap > 0 && b.graduationCap <= b.totalSupply, "Invalid graduation cap");

    factory.createAdvancedToken{value: msg.value}(b, s, a, msg.sender, taxWallets, taxSplits);
}


function createAdvancedTokenStealth(
    IKitchenFactory.BasicParamsAdvanced calldata b,
    IKitchenFactory.StaticCurveParams calldata s,
    IKitchenFactory.AdvancedParamsInput calldata a,
    address[4] calldata taxWallets,
    uint8[4] calldata taxSplits
) external payable {
    _validateVirtualParams(b.totalSupply, s.curveMaxWallet, s.curveMaxTx);
    // --- Validate graduationCap is within bounds 36k - 500k USD->ETH->TOKEN---
    _validateGradCapUSDRange(b.totalSupply, b.graduationCap, 0);
    // --- Validate graduationCap in token units ---
    require(b.graduationCap > 0 && b.graduationCap <= b.totalSupply, "Invalid graduation cap");


    factory.createAdvancedTokenStealth{value: msg.value}(b, s, a, msg.sender, taxWallets, taxSplits);

}


function createSuperSimpleToken(
    KitchenStorage.TokenSuperSimple calldata meta,
    uint256 startTime,
    bool isStealth
) external payable {
    require(meta.totalSupply > MIN_SUPPLY && meta.totalSupply <= MAX_SUPPLY, "Invalid supply");
    require(meta.maxWallet >= meta.totalSupply / MW_DIVISOR, "maxWallet too small");
    require(meta.maxTx >= meta.totalSupply / MT_DIVISOR, "maxTx too small");
    // --- Validate graduationCap is within bounds 36k - 500k USD->ETH->TOKEN---
    _validateGradCapUSDRange(meta.totalSupply, meta.graduationCap, 0);
    // --- Validate graduationCap in token units ---
    require(meta.graduationCap > 0 && meta.graduationCap <= meta.totalSupply, "Invalid graduation cap");


    factory.createSuperSimpleToken{value: msg.value}(meta, startTime, isStealth, msg.sender);

}


function createZeroSimpleToken(
    KitchenStorage.TokenZeroSimple calldata meta,
    uint256 startTime,
    bool isStealth
) external payable {
    require(meta.totalSupply > MIN_SUPPLY && meta.totalSupply <= MAX_SUPPLY, "Invalid supply");
    // --- Validate graduationCap is within bounds 36k - 500k USD->ETH->TOKEN---
    _validateGradCapUSDRange(meta.totalSupply, meta.graduationCap, 0);
    // --- Validate graduationCap in token units ---
    require(meta.graduationCap > 0 && meta.graduationCap <= meta.totalSupply, "Invalid graduation cap");


    factory.createZeroSimpleToken{value: msg.value}(meta, startTime, isStealth, msg.sender);

}

    // ---------- GRADUATION / TRADING ----------
function graduateToken(address token) external {
    graduation.graduateToken(token, msg.sender); // forward last-buyer/stipend receiver
}

    function buyToken(address token) external payable {
        require(!storageContract.getTokenState(token).graduated, "Token has graduated");
        kitchenBondingCurve.buyTokenFor{value: msg.value}(token, msg.sender);
    }

    function sellToken(address token, uint256 amount) external {
        require(!storageContract.getTokenState(token).graduated, "Token has graduated");
        require(amount > 0, "amount=0");
        uint256 bal = storageContract.getUserBalance(msg.sender, token);
        require(bal >= amount, "insufficient");
        kitchenBondingCurve.sellTokenFor(token, msg.sender, amount);
    }

// ---- NEW: slippage-protected trade paths (optional) ----
function buyTokenWithMinOut(address token, uint256 minTokensOut) external payable {
    require(!storageContract.getTokenState(token).graduated, "Token has graduated");
    require(msg.value > 0, "ETH=0");
    kitchenBondingCurve.buyTokenForWithMinOut{value: msg.value}(token, msg.sender, minTokensOut);
}

function sellTokenWithMinOut(address token, uint256 amount, uint256 minEthOut) external {
    require(!storageContract.getTokenState(token).graduated, "Token has graduated");
    require(amount > 0, "amount=0");
    uint256 bal = storageContract.getUserBalance(msg.sender, token);
    require(bal >= amount, "insufficient");
    kitchenBondingCurve.sellTokenForWithMinOut(token, msg.sender, amount, minEthOut);
}

function getConfig() external view returns (
    address _factory,
    address _bondingCurve,
    address _graduation,
    address _storage,
    address _deployer,
    address _owner
) {
    return (
        address(factory),
        address(kitchenBondingCurve),
        address(graduation),
        address(storageContract),
        address(deployer),
        owner
    );
}

function emergencyWithdraw(address payable to)
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

/// @notice View helper: expected ETH in pool at graduation vs. min/max ETH bounds
function validateGraduationEthRange(
    uint256 totalSupply,
    uint256 ethPool,
    uint256 circ,
    uint256 gradCapTokens
) external view returns (bool withinRange, uint256 ethAtCap, uint256 minEth, uint256 maxEth) {
    (uint256 ethUsdPrice, uint256 updatedAt) = oracle.ethUsd();
    if (ethUsdPrice == 0 || block.timestamp - updatedAt > 10_800) return (false, 0, 0, 0);

    (, , uint256 capMinUsd, uint256 capMaxUsd, ) = storageContract.getConfig();
    minEth = (capMinUsd * 1e18) / ethUsdPrice;
    maxEth = (capMaxUsd * 1e18) / ethUsdPrice;
    ethAtCap = KitchenCurveMaths.getEthForTokens(totalSupply, ethPool, circ, gradCapTokens);
    withinRange = (ethAtCap >= minEth && ethAtCap <= maxEth);
}



receive() external payable {}


}
