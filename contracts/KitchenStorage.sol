// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenTimelock.sol";

/**
 * @title KitchenStorage
 * @dev Central storage contract for the Steakhouse token system.
 *
 * Now fully standardized: all numeric fields are uint256 for concordance
 * with Kitchen + Factory and ERC-20 18 decimals.
 */
contract KitchenStorage is KitchenTimelock {
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
        // --- NEW MULTI-TAX WALLET SUPPORT ---
        address[4] taxWallets;   // up to 4 wallets to receive split tax
        uint8[4]   taxSplits;    // % shares out of 100 (sum must equal 100)


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
        uint256 limitsStart;          // when anti-whale limits begin (now tied to startTime)
    }

    // =====================================================
    // CLAIM-MODE STATE (for >300 holders graduation)
    // =====================================================

    // virtualToken => claimMode enabled
    mapping(address => bool) private _claimMode;

    // virtualToken => (user => claimed)
    mapping(address => mapping(address => bool)) private _hasClaimed;

    // virtualToken => current index in buyers[] for chunked sweeping
    mapping(address => uint256) private _claimCursor;

// ------------------------------------------------------------
// USD Graduation Boundaries (for creation-time validation only)
// ------------------------------------------------------------
// Used to validate the USD graduation target a dev supplies at creation.
// No longer used at runtime — tokens store ETH caps individually.
uint256 public capMinUsd;     // e.g. 36,000 * 1e8  (8-dec Chainlink style)
uint256 public capMaxUsd;     // e.g. 500,000 * 1e8
uint256 public overshootBps;  // default 1000 = 10 %


    // ============== EVENTS ==============
    event ClaimModeEnabled(address indexed virtualToken, bool enabled);
    event Claimed(address indexed virtualToken, address indexed user, uint256 amount);

    // ============== SETTERS / GETTERS ==============

    /// @notice Enable or disable claim-mode for a graduated token
    function setClaimMode(address virtualToken, bool on) external onlyAuthorized {
        _claimMode[virtualToken] = on;
        emit ClaimModeEnabled(virtualToken, on);
    }

    /// @notice Check if claim-mode is active for a token
    function isClaimMode(address virtualToken) external view returns (bool) {
        return _claimMode[virtualToken];
    }

    /// @notice Mark a user as having claimed their tokens
    function setHasClaimed(address virtualToken, address user, bool v) external onlyAuthorized {
        _hasClaimed[virtualToken][user] = v;
    }

    /// @notice Returns whether a user has already claimed
    function hasClaimed(address virtualToken, address user) external view returns (bool) {
        return _hasClaimed[virtualToken][user];
    }

    /// @notice Returns sweep cursor index for distributeRemaining
    function getClaimCursor(address virtualToken) external view returns (uint256) {
        return _claimCursor[virtualToken];
    }

    /// @notice Set sweep cursor index
    function setClaimCursor(address virtualToken, uint256 i) external onlyAuthorized {
        _claimCursor[virtualToken] = i;
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



    // ========== EVENTS ==========
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event AuthorizedCallerUpdated(address indexed caller, bool status);

constructor(address _treasury) {
    owner = msg.sender;
    steakhouseTreasury = _treasury;

    // Default USD boundaries for creation-time validation
    capMinUsd = 36_000 * 1e8;   // $36 k
    capMaxUsd = 500_000 * 1e8;  // $500 k
    overshootBps = 1000;        // 10 %

    lastVolumeResetTimestamp = block.timestamp;
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

// O(1) index for buyers[token] using 1-based indexing (0 == not present)
mapping(address => mapping(address => uint256)) private buyerIndex;

// Creator tracking

mapping(address => address[]) public _tokensByCreator;
mapping(address => address[]) private _stealthTokensByCreator;
mapping(address => address)   public tokenLPs;
mapping(address => address)   public realTokenAddress;

// --- NEW MULTI-TAX STORAGE ---
mapping(address => address[4]) public tokenTaxWallets;
mapping(address => uint8[4])   public tokenTaxSplits;


// Analytics

mapping(address => uint256) public devEarnings;
mapping(address => uint256) public volumeByToken;
mapping(address => uint256) public tradesByToken;
mapping(address => bool)    public isTokenGraduated;

mapping(address => uint256) public postGradBuybackEth;
mapping(address => uint256) public postGradTokensBurned;

// Per-wallet analytics
mapping(address => mapping(address => uint256)) public walletBuyVolumeByToken;
mapping(address => mapping(address => uint256)) public walletSellVolumeByToken;
mapping(address => uint256) public walletBuyVolume;
mapping(address => uint256) public walletSellVolume;

// --- CREATOR EXEMPTION WINDOW ---
// Records a 6-second post-launch exemption from maxTx and maxWallet rules for creator
mapping(address => address) public tokenCreator;
mapping(address => uint256) public creatorBuyExemptUntil;

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
    function getTokenTaxInfo(address token) external view returns (address[4] memory wallets, uint8[4] memory splits){ return (tokenTaxWallets[token], tokenTaxSplits[token]);}
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
        // Record creator exemption data (6s window from creation)
        tokenCreator[token] = data.creator;
        creatorBuyExemptUntil[token] = block.timestamp + 6;
        _bumpDailyCreateCounters();
    }
    function setTokenAdvanced(address token, TokenAdvanced memory data) external onlyAuthorized {
        _tokensAdvanced[token] = data;
        isAdvancedToken[token] = true;
        tokenCurveProfile[token] = CurveProfile.ADVANCED;
        deployedTokens.push(token);
        _tokensByCreator[data.creator].push(token);
        // Record creator exemption data (6s window from creation)
        tokenCreator[token] = data.creator;
        creatorBuyExemptUntil[token] = block.timestamp + 6;
        _bumpDailyCreateCounters();
        // Save multi-tax wallet config if provided
        if (data.taxWallets[0] != address(0)) {
            tokenTaxWallets[token] = data.taxWallets;
            tokenTaxSplits[token]  = data.taxSplits;
        }

    }
    function setTokenSuperSimple(address token, TokenSuperSimple memory data) external onlyAuthorized {
        _tokensSuperSimple[token] = data;
        isSuperSimpleToken[token] = true; 
        tokenCurveProfile[token] = CurveProfile.SUPER_SIMPLE;
        deployedTokens.push(token);
        _tokensByCreator[data.creator].push(token);
        // Record creator exemption data (6s window from creation)
        tokenCreator[token] = data.creator;
        creatorBuyExemptUntil[token] = block.timestamp + 6;
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
        // Record creator exemption data (6s window from creation)
        tokenCreator[token] = data.creator;
        creatorBuyExemptUntil[token] = block.timestamp + 6;
    }
    function setTokenAdvancedStealth(address token, TokenAdvanced memory data) external onlyAuthorized {
        _tokensAdvanced[token] = data;
        isAdvancedToken[token] = true;
        tokenCurveProfile[token] = CurveProfile.ADVANCED;
        isStealthToken[token] = true;
        _stealthTokensByCreator[data.creator].push(token);
        // Record creator exemption data (6s window from creation)
        tokenCreator[token] = data.creator;
        creatorBuyExemptUntil[token] = block.timestamp + 6;
        // Save multi-tax wallet config if provided
        if (data.taxWallets[0] != address(0)) {
            tokenTaxWallets[token] = data.taxWallets;
            tokenTaxSplits[token]  = data.taxSplits;
        }

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

function setTokenTaxInfo(address token, address[4] calldata wallets, uint8[4] calldata splits)
    external
    onlyAuthorized
{
    tokenTaxWallets[token] = wallets;
    tokenTaxSplits[token]  = splits;
}


    // ========== STATE ==========
    function setTokenState(address token, TokenState memory data) external onlyAuthorized {
        if (data.limitsStart == 0) data.limitsStart = data.startTime;
        _tokenState[token] = data;
    }

    function updateTokenState(address token, uint256 ethPool, uint256 circulatingSupply) external onlyAuthorized {
        _tokenState[token].ethPool = ethPool; _tokenState[token].circulatingSupply = circulatingSupply;
    }
    function setTokenLP(address token, address lp) external onlyAuthorized { tokenLPs[token] = lp; }
    function setRealTokenAddress(address virtualToken, address realToken) external onlyAuthorized { realTokenAddress[virtualToken] = realToken; }
    function markTokenGraduated(address token) external onlyAuthorized {
        if (!isTokenGraduated[token]) { isTokenGraduated[token] = true; totalGraduatedTokens++; }
    }


function getCreatorExemptInfo(address token) external view returns (address creator, uint256 until) {
    return (tokenCreator[token], creatorBuyExemptUntil[token]);
}
    
function clearBuyers(address token) external onlyAuthorized {
    // clean buyerIndex for each current buyer, then clear the array
    address[] storage arr = buyers[token];
    uint256 len = arr.length;
    for (uint256 i = 0; i < len; i++) {
        delete buyerIndex[token][arr[i]];
    }
    delete buyers[token];
}


    // ========== USER ==========
    // Buyer and balance management used by the bonding curve. `addBuyer` only
    // pushes the address if the user's pre-existing balance was zero.
    function updateUserBalance(address user, address token, uint256 amount) external onlyAuthorized { userBalances[user][token] = amount; }

function addBuyer(address token, address user) external onlyAuthorized {
    // Only add when the user previously had zero balance and is not already indexed
    if (userBalances[user][token] == 0 && buyerIndex[token][user] == 0) {
        buyers[token].push(user);
        buyerIndex[token][user] = buyers[token].length; // store index+1
    }
}

function removeBuyer(address token, address user) external onlyAuthorized {
    if (userBalances[user][token] == 0) {
        uint256 idxPlus1 = buyerIndex[token][user];
        if (idxPlus1 == 0) return; // not present / already removed

        uint256 index = idxPlus1 - 1;
        address[] storage arr = buyers[token];
        uint256 lastIndex = arr.length - 1;

        if (index != lastIndex) {
            address last = arr[lastIndex];
            arr[index] = last;
            buyerIndex[token][last] = index + 1; // fix moved element index
        }

        arr.pop();
        delete buyerIndex[token][user];
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

/// @notice Record ETH spent and tokens burned during post-graduation auto buyback.
/// @dev Only callable by authorized modules (e.g., KitchenGraduation).
function recordPostGradBuyback(
    address token,
    uint256 ethSpent,
    uint256 tokensBurned
) external onlyAuthorized {
    if (ethSpent > 0) {
        postGradBuybackEth[token] += ethSpent;
    }
    if (tokensBurned > 0) {
        postGradTokensBurned[token] += tokensBurned;
    }
}


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
    function authorizeCaller(address caller, bool status) external onlyAuthorized timelocked(keccak256("UPDATE_AUTH")) {
        authorizedCallers[caller] = status; emit AuthorizedCallerUpdated(caller, status);
    }
    function authorizeModule(address module) external onlyAuthorized timelocked(keccak256("UPDATE_MODULE")) {
        authorizedCallers[module] = true; emit AuthorizedCallerUpdated(module, true);
    }
// ------------------------------------------------------------
// Admin: Update USD Graduation Bounds
// ------------------------------------------------------------
event GraduationBoundsUpdated(uint256 minUsd, uint256 maxUsd, uint256 overshootBps);

function setGraduationBoundsUSD(
    uint256 _capMinUsd,
    uint256 _capMaxUsd,
    uint256 _overshootBps
) external onlyAuthorized timelocked(keccak256("UPDATE_GRAD_BOUNDS_USD")) {
    require(_capMinUsd > 0, "min=0");
    require(_capMaxUsd > _capMinUsd, "max<=min");
    require(_overshootBps <= 5000, "overshoot>50%");
    capMinUsd = _capMinUsd;
    capMaxUsd = _capMaxUsd;
    overshootBps = _overshootBps;
    emit GraduationBoundsUpdated(_capMinUsd, _capMaxUsd, _overshootBps);
}

    function updateTreasury(address newTreasury) external onlyAuthorized timelocked(keccak256("updateTreasury")) {
        require(newTreasury != address(0), "Invalid treasury");
        emit TreasuryUpdated(steakhouseTreasury, newTreasury); steakhouseTreasury = newTreasury;
    }


event VolumeResetPeriodUpdated(uint256 newPeriod);
uint256 public volumeResetPeriod = 1 days;

function updateVolumeResetPeriod(uint256 newPeriod)
    external
    onlyAuthorized
    timelocked(keccak256("updateVolumeResetPeriod"))
{
    require(newPeriod >= 1 hours && newPeriod <= 7 days, "Invalid period");
    volumeResetPeriod = newPeriod;
    emit VolumeResetPeriodUpdated(newPeriod);
}

event GlobalNonceReset(uint256 oldNonce, uint256 newNonce);
function resetGlobalNonce(uint256 newValue)
    external
    onlyAuthorized
    timelocked(keccak256("resetGlobalNonce"))
{
    emit GlobalNonceReset(globalNonce, newValue);
    globalNonce = newValue;
}


// === Treasury skim percentage (basis points) ===
// Used by KitchenBondingCurve to send part of dev/tax fee to treasury.
// Default = 10% (1000 BPS)
uint256 public treasuryCutBps = 1000;

event TreasuryCutUpdated(uint256 oldBps, uint256 newBps);

function setTreasuryCutBps(uint256 newBps) external onlyAuthorized timelocked(keccak256("UPDATE_CUT_BPS")) {
    require(newBps <= 2500, "Too high"); // max 25%
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

function setAntiPvpCooldown(uint256 newCooldown) external onlyAuthorized timelocked(keccak256("UPDATE_PVP_COOLDOWN")) {
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
    uint256 _capMinUsd,
    uint256 _capMaxUsd,
    uint256 _overshootBps
) {
    return (steakhouseTreasury, owner, capMinUsd, capMaxUsd, overshootBps);
}




}