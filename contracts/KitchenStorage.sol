// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title KitchenStorage
 * @dev Central storage contract for the Steakhouse token system.
 *
 * Now fully standardized: all numeric fields are uint256 for concordance
 * with Kitchen + Factory and ERC-20 18 decimals.
 */
contract KitchenStorage {
    // ========== ENUMS ==========

    enum TokenType { NO_TAX, TAX }
    enum CurveProfile { BASIC, ADVANCED, SUPER_SIMPLE, ZERO_SIMPLE }

    // ========== STRUCTS ==========

    struct LPLockConfig {
    // Configuration for what happens to LP at graduation launch
    uint256 lpLockDuration; // seconds - how long LP is locked in locker
    bool burnLP;            // if true, LP is burned instead of locked
    }

    // ------- BASIC -------
    // Metadata and parameters for BASIC profile tokens. These fields are
    // consumed by creator, bonding curve, and graduation flows.
    struct TokenBasic {
        address creator;
        string name;
        string symbol;
        uint256 totalSupply;        
        uint256 graduationCap;      

        // curve tax & durations
        uint256 curveStartingTax;
        uint256 curveTaxDuration;

        // limits (during curve)
        uint256 curveMaxWallet;         
        uint256 curveMaxWalletDuration; 
        uint256 curveMaxTx;             
        uint256 curveMaxTxDuration;     

        TokenType tokenType;           
        uint256 finalTaxRate;          // percent (0–5)
        bool removeHeader;             
        LPLockConfig lpConfig;
    }

    // ------- ADVANCED -------
    struct TokenAdvanced {
        address creator;
        string name;
        string symbol;
        uint256 totalSupply;       
        uint256 graduationCap;     
        address taxWallet;

        // dynamic tax decay
        uint256 curveStartingTax;   
        uint256 taxDropStep;        
        uint256 taxDropInterval;    

        // dynamic limits
        uint256 maxWalletStart;     
        uint256 maxWalletStep;      
        uint256 maxWalletInterval;  
        uint256 maxTxStart;         
        uint256 maxTxStep;          
        uint256 maxTxInterval;      
        uint256 limitRemovalTime;   

        TokenType tokenType;
        uint256 finalTaxRate;        
        bool removeHeader;
        LPLockConfig lpConfig;
    }

    // ------- SUPER SIMPLE -------
    struct TokenSuperSimple {
        address creator;
        string name;
        string symbol;
        uint256 totalSupply;        
        uint256 graduationCap;      

        uint256 maxWallet;           
        uint256 maxTx;               

        TokenType tokenType;        
        uint256 finalTaxRate;         
        bool removeHeader;
        LPLockConfig lpConfig;
    }

    // ------- ZERO SIMPLE -------
    struct TokenZeroSimple {
        address creator;
        string name;
        string symbol;
        uint256 totalSupply;        
        uint256 graduationCap;      

        TokenType tokenType;        
        uint256 finalTaxRate;         
        bool removeHeader;
        LPLockConfig lpConfig;
    }

    // ------- Bonding curve state -------
    struct TokenState {
        // Mutable runtime state used by the bonding curve and graduation.
        uint256 ethPool;              // ETH currently held by the virtual pool
        uint256 circulatingSupply;    // tokens issued to buyers
        bool graduated;               // whether V2 has been deployed and LP finalized
        uint256 createdAtBlock;       // block when token was created
        uint256 createdAtTimestamp;   // timestamp when token was created
        uint256 startTime;            // when trading may begin
    }

    // ========== ACCESS CONTROL ==========
    address public owner;
    address public steakhouseTreasury;
    mapping(address => bool) public authorizedCallers;

    // Only owner or an authorized module can mutate storage. This centralizes
    // access control for system modules (Factory, Curve, Graduation, etc.).
    modifier onlyAuthorized() {
        require(msg.sender == owner || authorizedCallers[msg.sender], "Not authorized");
        _;
    }

    // ========== SYSTEM CONFIG ==========
    
    // ========== GLOBAL NONCE ==========
    // Used by KitchenCreatorBasicAdvanced and KitchenCreatorSimple to prevent address collisions.
    uint256 public globalNonce;

    /// @notice Increments and returns the shared nonce across all creator modules.
    /// @dev Called by authorized creator contracts to ensure unique CREATE2 salts.
    function incrementNonce() external onlyAuthorized returns (uint256 newNonce) {
        newNonce = ++globalNonce;
    }


    uint256 public minEthAtCap;   
    uint256 public maxEthAtCap;   
    uint256 public overshootBps;  

    // ========== EVENTS ==========
    event GraduationBoundsUpdated(uint256 minEthAtCap, uint256 maxEthAtCap, uint256 overshootBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event AuthorizedCallerUpdated(address indexed caller, bool status);

    constructor(address _treasury) {
        owner = msg.sender;
        steakhouseTreasury = _treasury;

        minEthAtCap = 1.9 ether;
        maxEthAtCap = 13.6 ether;
        overshootBps = 1000; // 10%

        lastVolumeResetTimestamp = block.timestamp; // NEW
    }

    // ========== STORAGE LAYOUT ==========
// Core token metadata

mapping(address => TokenBasic)       internal _tokensBasic;
mapping(address => TokenAdvanced)    internal _tokensAdvanced;
mapping(address => TokenSuperSimple) internal _tokensSuperSimple;
mapping(address => TokenZeroSimple)  internal _tokensZeroSimple;
mapping(address => TokenState)       internal _tokenState;

// Token flags/config

mapping(address => bool)         public isAdvancedToken;
mapping(address => CurveProfile) public tokenCurveProfile;
mapping(address => bool)         public isStealthToken;
mapping(address => bool)         public removeHeaderOnDeploy;
mapping(address => bool)         public isSuperSimpleToken;  
mapping(address => bool)         public isZeroSimpleToken;    

// User balances & buyers

mapping(address => mapping(address => uint256)) public userBalances;
mapping(address => address[]) public buyers;

// Creator tracking

mapping(address => address[]) public _tokensByCreator;
mapping(address => address[]) private _stealthTokensByCreator;
mapping(address => address)   public tokenLPs;
mapping(address => address)   public realTokenAddress;


// Analytics

mapping(address => uint256) public devEarnings;
mapping(address => uint256) public volumeByToken;
mapping(address => uint256) public tradesByToken;
mapping(address => bool)    public isTokenGraduated;

// Per-wallet analytics
mapping(address => mapping(address => uint256)) public walletBuyVolumeByToken;
mapping(address => mapping(address => uint256)) public walletSellVolumeByToken;
mapping(address => uint256) public walletBuyVolume;
mapping(address => uint256) public walletSellVolume;


// System Stats

address[] public deployedTokens;
uint256 public totalTokensCreated;
uint256 public totalGraduatedTokens;
uint256 public totalVolume24h;
uint256 public totalVolumeLifetime;
uint256 public tokensCreatedToday;
uint256 public lastTokenCreationTimestamp;

// NEW: rolling 24h volume reset
uint256 public lastVolumeResetTimestamp;

// Anti-PVP ticker/name tracking
struct LaunchRecord {
    string name;
    string symbol;
    uint256 timestamp;
}

mapping(bytes32 => LaunchRecord) public recentLaunches;
uint256 public antiPvpCooldown = 3 days;

event AntiPvpCooldownUpdated(uint256 newCooldown);


    // ========== GETTERS ==========
    // Lightweight accessors used by other modules to read token metadata/state.
    function getTokenBasic(address token) external view returns (TokenBasic memory) { return _tokensBasic[token]; }
    function getTokenAdvanced(address token) external view returns (TokenAdvanced memory) { return _tokensAdvanced[token]; }
    function getTokenSuperSimple(address token) external view returns (TokenSuperSimple memory) { return _tokensSuperSimple[token]; }
    function getTokenZeroSimple(address token) external view returns (TokenZeroSimple memory) { return _tokensZeroSimple[token]; }
    function getTokenState(address token) external view returns (TokenState memory) { return _tokenState[token]; }
    function getUserBalance(address user, address token) external view returns (uint256) { return userBalances[user][token]; }
    function getDeployedTokens() external view returns (address[] memory) { return deployedTokens; }
    function getBuyers(address token) external view returns (address[] memory) { return buyers[token]; }
    function getTokensByCreator(address creator) external view returns (address[] memory) { return _tokensByCreator[creator]; }
    function getStealthTokensByCreator(address creator) external view returns (address[] memory) {
        require(msg.sender == creator || msg.sender == owner, "Not authorized to view stealth");
        return _stealthTokensByCreator[creator];
    }
    function getGraduationRate() external view returns (uint256 ratePercent) {
        if (totalTokensCreated == 0) return 0;
        return (totalGraduatedTokens * 100) / totalTokensCreated;
    }
    function getTokenLP(address token) external view returns (address) { return tokenLPs[token]; }
    function getRealTokenAddress(address token) external view returns (address) { return realTokenAddress[token]; }
    function getIsAdvancedToken(address token) external view returns (bool) { return isAdvancedToken[token]; }

    // ========== SETTERS ==========
    // Storage setters called by Creator modules during token creation. These
    // are guarded by onlyAuthorized to prevent arbitrary writes.
    function setTokenBasic(address token, TokenBasic memory data) external onlyAuthorized {
        _tokensBasic[token] = data;
        tokenCurveProfile[token] = CurveProfile.BASIC;
        deployedTokens.push(token);
        _tokensByCreator[data.creator].push(token);
        _bumpDailyCreateCounters();
    }
    function setTokenAdvanced(address token, TokenAdvanced memory data) external onlyAuthorized {
        _tokensAdvanced[token] = data;
        isAdvancedToken[token] = true;
        tokenCurveProfile[token] = CurveProfile.ADVANCED;
        deployedTokens.push(token);
        _tokensByCreator[data.creator].push(token);
        _bumpDailyCreateCounters();
    }
    function setTokenSuperSimple(address token, TokenSuperSimple memory data) external onlyAuthorized {
        _tokensSuperSimple[token] = data;
        isSuperSimpleToken[token] = true; 
        tokenCurveProfile[token] = CurveProfile.SUPER_SIMPLE;
        deployedTokens.push(token);
        _tokensByCreator[data.creator].push(token);
        _bumpDailyCreateCounters();
    }
    function setTokenZeroSimple(address token, TokenZeroSimple memory data) external onlyAuthorized {
        _tokensZeroSimple[token] = data;
        isZeroSimpleToken[token] = true;
        tokenCurveProfile[token] = CurveProfile.ZERO_SIMPLE;
        deployedTokens.push(token);
        _tokensByCreator[data.creator].push(token);
        _bumpDailyCreateCounters();
    }
    function setRemoveHeader(address token, bool flag) external onlyAuthorized { removeHeaderOnDeploy[token] = flag; }

    // ========== STEALTH ==========
    function setTokenBasicStealth(address token, TokenBasic memory data) external onlyAuthorized {
        _tokensBasic[token] = data;
        tokenCurveProfile[token] = CurveProfile.BASIC;
        isStealthToken[token] = true;
        _stealthTokensByCreator[data.creator].push(token);
    }
    function setTokenAdvancedStealth(address token, TokenAdvanced memory data) external onlyAuthorized {
        _tokensAdvanced[token] = data;
        isAdvancedToken[token] = true;
        tokenCurveProfile[token] = CurveProfile.ADVANCED;
        isStealthToken[token] = true;
        _stealthTokensByCreator[data.creator].push(token);
    }
    function setTokenSuperSimpleStealth(address token, TokenSuperSimple memory data) external onlyAuthorized {
        _tokensSuperSimple[token] = data;
        isSuperSimpleToken[token] = true;
        tokenCurveProfile[token] = CurveProfile.SUPER_SIMPLE;
        isStealthToken[token] = true;
        _stealthTokensByCreator[data.creator].push(token);
    }
    function setTokenZeroSimpleStealth(address token, TokenZeroSimple memory data) external onlyAuthorized {
        _tokensZeroSimple[token] = data;
        isZeroSimpleToken[token] = true;
        tokenCurveProfile[token] = CurveProfile.ZERO_SIMPLE;
        isStealthToken[token] = true;
        _stealthTokensByCreator[data.creator].push(token);
    }

    // ========== STATE ==========
    function setTokenState(address token, TokenState memory data) external onlyAuthorized { _tokenState[token] = data; }
    function updateTokenState(address token, uint256 ethPool, uint256 circulatingSupply) external onlyAuthorized {
        _tokenState[token].ethPool = ethPool; _tokenState[token].circulatingSupply = circulatingSupply;
    }
    function setTokenLP(address token, address lp) external onlyAuthorized { tokenLPs[token] = lp; }
    function setRealTokenAddress(address virtualToken, address realToken) external onlyAuthorized { realTokenAddress[virtualToken] = realToken; }
    function markTokenGraduated(address token) external onlyAuthorized {
        if (!isTokenGraduated[token]) { isTokenGraduated[token] = true; totalGraduatedTokens++; }
    }
    function clearBuyers(address token) external onlyAuthorized { delete buyers[token]; }

    // ========== USER ==========
    // Buyer and balance management used by the bonding curve. `addBuyer` only
    // pushes the address if the user's pre-existing balance was zero.
    function updateUserBalance(address user, address token, uint256 amount) external onlyAuthorized { userBalances[user][token] = amount; }
    function addBuyer(address token, address user) external onlyAuthorized { if (userBalances[user][token] == 0) buyers[token].push(user); }
    function removeBuyer(address token, address user) external onlyAuthorized {
        if (userBalances[user][token] == 0) {
            address[] storage arr = buyers[token]; uint256 len = arr.length;
            for (uint256 i = 0; i < len; ++i) { if (arr[i] == user) { arr[i] = arr[len - 1]; arr.pop(); break; } }
        }
    }

    /// Get all token balances for a user across deployed tokens
    function getUserBalances(address user) external view returns (
        address[] memory tokens,
        uint256[] memory balances
    ) {
        uint256 len = deployedTokens.length;
        tokens = new address[](len);
        balances = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address token = deployedTokens[i];
            tokens[i] = token;
            balances[i] = userBalances[user][token];
        }
    }


    // ========== ANALYTICS ==========
    // Small helpers used to aggregate on-chain metrics (volume, earnings, trade counts)

    function getBuyerCount(address token) external view returns (uint256) {
    return buyers[token].length;
    }

    // Tracks all dev/tax ETH distributed (live per-trade payments)
    function incrementDevEarnings(address token, uint256 amount) external onlyAuthorized { devEarnings[token] += amount; }

    function incrementTokenVolume(address token, uint256 amount) external onlyAuthorized {
        // Reset if > 24h has passed since last reset
    if (block.timestamp > lastVolumeResetTimestamp + 1 days) {
        totalVolume24h = 0;
        lastVolumeResetTimestamp = block.timestamp;
    }

    volumeByToken[token] += amount;
    totalVolume24h += amount;
    totalVolumeLifetime += amount;
    }

    function incrementTradeCount(address token) external onlyAuthorized { tradesByToken[token]++; }
    
    // get token holder count 
    function getHolderCount(address token) external view returns (uint256) {
        return buyers[token].length;
    }

function incrementWalletBuyVolumeByToken(address wallet, address token, uint256 ethIn) external onlyAuthorized {
    walletBuyVolumeByToken[token][wallet] += ethIn;
    walletBuyVolume[wallet] += ethIn; // keep global totals too
}

function incrementWalletSellVolumeByToken(address wallet, address token, uint256 ethOut) external onlyAuthorized {
    walletSellVolumeByToken[token][wallet] += ethOut;
    walletSellVolume[wallet] += ethOut; // keep global totals too
}


function incrementWalletBuyVolume(address wallet, uint256 ethIn) external onlyAuthorized {
    walletBuyVolume[wallet] += ethIn;
}

function incrementWalletSellVolume(address wallet, uint256 ethOut) external onlyAuthorized {
    walletSellVolume[wallet] += ethOut;
}

function getTotalVolume24h() external view returns (uint256) {
    if (block.timestamp > lastVolumeResetTimestamp + 1 days) {
        return 0;
    }
    return totalVolume24h;
}

    // === Per-wallet analytics getters ===
    function getWalletBuyVolume(address wallet) external view returns (uint256) {
        return walletBuyVolume[wallet];
    }

    function getWalletSellVolume(address wallet) external view returns (uint256) {
        return walletSellVolume[wallet];
    }

    function getWalletBuyVolumeByToken(address token, address wallet) external view returns (uint256) {
        return walletBuyVolumeByToken[token][wallet];
    }

    function getWalletSellVolumeByToken(address token, address wallet) external view returns (uint256) {
        return walletSellVolumeByToken[token][wallet];
    }

    // Extra getters volume reset and daioly creation stamp of tokens created

        function getLastVolumeResetTimestamp() external view returns (uint256) {
        return lastVolumeResetTimestamp;
    }

        function getDailyCreationStats() external view returns (uint256 today, uint256 lastTs) {
        return (tokensCreatedToday, lastTokenCreationTimestamp);
    }





    // ========== AUTH ==========
    function authorizeCaller(address caller, bool status) external onlyAuthorized {
        authorizedCallers[caller] = status; emit AuthorizedCallerUpdated(caller, status);
    }
    function authorizeModule(address module) external onlyAuthorized {
        authorizedCallers[module] = true; emit AuthorizedCallerUpdated(module, true);
    }
    function updateTreasury(address newTreasury) external onlyAuthorized {
        require(newTreasury != address(0), "Invalid treasury");
        emit TreasuryUpdated(steakhouseTreasury, newTreasury); steakhouseTreasury = newTreasury;
    }
    function setGraduationBounds(uint256 _minEthAtCap,uint256 _maxEthAtCap,uint256 _overshootBps) external onlyAuthorized {
        require(_minEthAtCap > 0, "min=0"); require(_maxEthAtCap > _minEthAtCap, "max<=min");
        require(_overshootBps <= 5000, "overshoot too high");
        minEthAtCap = _minEthAtCap; maxEthAtCap = _maxEthAtCap; overshootBps = _overshootBps;
        emit GraduationBoundsUpdated(_minEthAtCap, _maxEthAtCap, _overshootBps);
    }

// === Treasury skim percentage (basis points) ===
// Used by KitchenBondingCurve to send part of dev/tax fee to treasury.
// Default = 10% (1000 BPS)
uint256 public treasuryCutBps = 1000;

event TreasuryCutUpdated(uint256 oldBps, uint256 newBps);

function setTreasuryCutBps(uint256 newBps) external onlyAuthorized {
    require(newBps <= 5000, "Too high"); // max 50%
    emit TreasuryCutUpdated(treasuryCutBps, newBps);
    treasuryCutBps = newBps;
}

    // ========== UTIL ==========
    function setCurveProfile(address token, CurveProfile profile) external onlyAuthorized { tokenCurveProfile[token] = profile; }
    function setStealthFlag(address token, bool stealth) external onlyAuthorized { isStealthToken[token] = stealth; }
    function addTokenToCreator(address creator, address token) external onlyAuthorized { _tokensByCreator[creator].push(token); }

// --- Anti-PVP management ---
function _recordLaunch(string memory name, string memory symbol) internal {
    bytes32 key = keccak256(abi.encodePacked(_normalize(name), _normalize(symbol)));
    recentLaunches[key] = LaunchRecord(name, symbol, block.timestamp);
}

function _normalize(string memory str) internal pure returns (string memory) {
    bytes memory b = bytes(str);
    for (uint256 i = 0; i < b.length; i++) {
        if (b[i] >= 0x41 && b[i] <= 0x5A) {
            b[i] = bytes1(uint8(b[i]) + 32); // uppercase → lowercase
        }
    }
    return string(b);
}

function checkLaunchAllowed(string memory name, string memory symbol) external view returns (bool) {
    bytes32 key = keccak256(abi.encodePacked(_normalize(name), _normalize(symbol)));
    LaunchRecord memory rec = recentLaunches[key];
    if (rec.timestamp == 0) return true;
    return block.timestamp >= rec.timestamp + antiPvpCooldown;
}

function setAntiPvpCooldown(uint256 newCooldown) external onlyAuthorized {
    require(newCooldown >= 1 days && newCooldown <= 7 days, "Invalid cooldown");
    antiPvpCooldown = newCooldown;
    emit AntiPvpCooldownUpdated(newCooldown);
}


    // ========== INTERNAL ==========
    function _bumpDailyCreateCounters() internal {
        if (block.timestamp / 1 days == lastTokenCreationTimestamp / 1 days) { tokensCreatedToday++; }
        else { tokensCreatedToday = 1; lastTokenCreationTimestamp = block.timestamp; }
        totalTokensCreated++;
    }

function getConfig() external view returns (
    address _treasury,
    address _owner,
    uint256 _minEthAtCap,
    uint256 _maxEthAtCap,
    uint256 _overshootBps
) {
    return (
        steakhouseTreasury,
        owner,
        minEthAtCap,
        maxEthAtCap,
        overshootBps
    );
}


}