// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenStorage.sol";
import "./KitchenEvents.sol";

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
        address taxWallet
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
        address taxWallet
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

/// @title Kitchen Router
contract Kitchen is KitchenEvents {
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
    function setFactory(address _factory) external onlyOwner { factory = IKitchenFactory(_factory); }
    function setKitchenBondingCurve(address _kitchenBondingCurve) external onlyOwner { kitchenBondingCurve = IKitchenBondingCurve(_kitchenBondingCurve); }
    function setGraduation(address _graduation) external onlyOwner { graduation = IKitchenGraduation(_graduation); }
    function setStorage(address _storage) external onlyOwner { storageContract = KitchenStorage(_storage); }
    function setDeployer(address _deployer) external onlyOwner { deployer = IKitchenDeployer(_deployer); }
    

    // ---------- CREATOR UTILS ----------
    function setHeaderlessPreference(address token, bool flag) external {
        KitchenStorage.CurveProfile p = storageContract.tokenCurveProfile(token);
        address creator;
        if (p == KitchenStorage.CurveProfile.ADVANCED) {
            creator = storageContract.getTokenAdvanced(token).creator;
        } else if (p == KitchenStorage.CurveProfile.BASIC) {
            creator = storageContract.getTokenBasic(token).creator;
        } else if (p == KitchenStorage.CurveProfile.SUPER_SIMPLE) {
            creator = storageContract.getTokenSuperSimple(token).creator;
        } else {
            creator = storageContract.getTokenZeroSimple(token).creator;
        }
        require(msg.sender == creator, "Only creator");
        storageContract.setRemoveHeader(token, flag);
    }

    // ---------- TOKEN CREATION (Curve-based) ----------
    function createBasicToken(
        IKitchenFactory.BasicParamsBasic calldata b,
        IKitchenFactory.StaticCurveParams calldata s
    ) external payable {
        _validateVirtualParams(b.totalSupply, s.curveMaxWallet, s.curveMaxTx);
        factory.createBasicToken{value: msg.value}(b, s, msg.sender);
    }

    function createBasicTokenStealth(
        IKitchenFactory.BasicParamsBasic calldata b,
        IKitchenFactory.StaticCurveParams calldata s
    ) external payable {
        _validateVirtualParams(b.totalSupply, s.curveMaxWallet, s.curveMaxTx);
        factory.createBasicTokenStealth{value: msg.value}(b, s, msg.sender);
    }

    function createAdvancedToken(
        IKitchenFactory.BasicParamsAdvanced calldata b,
        IKitchenFactory.StaticCurveParams calldata s,
        IKitchenFactory.AdvancedParamsInput calldata a,
        address taxWallet
    ) external payable {
        _validateVirtualParams(b.totalSupply, s.curveMaxWallet, s.curveMaxTx);
        factory.createAdvancedToken{value: msg.value}(b, s, a, msg.sender, taxWallet);
    }

    function createAdvancedTokenStealth(
        IKitchenFactory.BasicParamsAdvanced calldata b,
        IKitchenFactory.StaticCurveParams calldata s,
        IKitchenFactory.AdvancedParamsInput calldata a,
        address taxWallet
    ) external payable {
        _validateVirtualParams(b.totalSupply, s.curveMaxWallet, s.curveMaxTx);
        factory.createAdvancedTokenStealth{value: msg.value}(b, s, a, msg.sender, taxWallet);
    }

    function createSuperSimpleToken(
        KitchenStorage.TokenSuperSimple calldata meta,
        uint256 startTime,
        bool isStealth
    ) external payable {
        // --- validation ---
        require(meta.totalSupply > MIN_SUPPLY && meta.totalSupply <= MAX_SUPPLY, "Invalid supply");
        require(meta.maxWallet >= meta.totalSupply / MW_DIVISOR,"maxWallet too small");
        require(meta.maxTx >= meta.totalSupply / MT_DIVISOR,"maxTx too small");
        factory.createSuperSimpleToken{value: msg.value}(meta, startTime, isStealth, msg.sender);
    }

    function createZeroSimpleToken(
        KitchenStorage.TokenZeroSimple calldata meta,
        uint256 startTime,
        bool isStealth
    ) external payable {
        // --- validation ---
        require(meta.totalSupply > MIN_SUPPLY && meta.totalSupply <= MAX_SUPPLY, "Invalid supply" );
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


    event BalanceTransferred(address indexed token, address indexed from, address indexed to, uint256 amount);



function transferCurveBalance(address token, address to, uint256 amount) external {
    require(to != address(0), "Zero address");
    require(!storageContract.getTokenState(token).graduated, "Token graduated");

    uint256 senderBal = storageContract.getUserBalance(msg.sender, token);
    require(senderBal >= amount && amount > 0, "Insufficient balance");

    // Update balances
    storageContract.updateUserBalance(msg.sender, token, senderBal - amount);

    uint256 receiverBal = storageContract.getUserBalance(to, token);
    if (receiverBal == 0) {
        storageContract.addBuyer(token, to);
    }
    storageContract.updateUserBalance(to, token, receiverBal + amount);

    // Remove sender if balance zero
    if (senderBal - amount == 0) {
        storageContract.removeBuyer(token, msg.sender);
    }

    emit BalanceTransferred(token, msg.sender, to, amount);
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

}
