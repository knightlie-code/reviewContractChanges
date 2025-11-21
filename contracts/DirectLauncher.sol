// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/* -------------------------------------------------
   Interfaces
------------------------------------------------- */
interface IDexRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,uint amountOutMin,address[] calldata path,address to,uint deadline
    ) external;
}
interface IDexFactory { function createPair(address, address) external returns (address); }
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/* -------------------------------------------------
   Import ERC20 implementation
------------------------------------------------- */
import { DirectLaunchTokenManual } from "./DirectLaunchERC20.sol";

/* -------------------------------------------------
   DirectLauncher (factory)
------------------------------------------------- */
contract DirectLauncher {
    event TokenLaunched(address indexed creator, address token, bool stealth);

    IDexRouter public immutable dexRouter;

    constructor(address _router) {
        dexRouter = IDexRouter(_router);
    }

    /* ------------------------------
       Manual Launch (just deploy)
    -------------------------------*/
    function launchManual(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        address taxWallet,
        address treasury,
        DirectLaunchTokenManual.DecayConfig memory decayCfg,
        DirectLaunchTokenManual.LimitsConfig memory limitsCfg
    ) public returns (address tokenAddr) {
        tokenAddr = address(new DirectLaunchTokenManual(
            name_,
            symbol_,
            supply_,
            taxWallet,
            treasury,
            decayCfg,
            limitsCfg,
            msg.sender // creator
        ));

        emit TokenLaunched(msg.sender, tokenAddr, false);
    }

    /* ------------------------------
       Stealth Launch (deploy + LP + enableTrading)
    -------------------------------*/
    function launchStealth(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        address taxWallet,
        address treasury,
        DirectLaunchTokenManual.DecayConfig memory decayCfg,
        DirectLaunchTokenManual.LimitsConfig memory limitsCfg,
        uint256 tokenAmount,    // tokens to seed LP
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint deadline
    ) public payable returns (address tokenAddr, address lpPair) {
        // 1. Deploy token with DirectLauncher as temp owner
        DirectLaunchTokenManual token = new DirectLaunchTokenManual(
            name_,
            symbol_,
            supply_,
            taxWallet,
            treasury,
            decayCfg,
            limitsCfg,
            address(this) // DirectLauncher is owner temporarily
        );
        tokenAddr = address(token);

        // 2. Approve router for liquidity
        IERC20(tokenAddr).approve(address(dexRouter), type(uint256).max);

        // 3. Add liquidity (ETH + tokens)
        dexRouter.addLiquidityETH{value: msg.value}(
            tokenAddr,
            tokenAmount,
            amountTokenMin,
            amountETHMin,
            msg.sender, // LP tokens go to creator
            deadline
        );

        // 4. Get LP pair from token
        lpPair = token.lpPair();

        // 5. Enable trading (onlyOwner, Launcher is owner now)
        token.enableTrading();

        // 6. Transfer ownership to creator
        token.transferOwnership(msg.sender);

        emit TokenLaunched(msg.sender, tokenAddr, true);
    }

    /* ------------------------------
       Unified Helper (Frontend Friendly)
    -------------------------------*/
    struct LaunchParams {
        string name;
        string symbol;
        uint256 supply;
        address taxWallet;
        address treasury;
        DirectLaunchTokenManual.DecayConfig decayCfg;
        DirectLaunchTokenManual.LimitsConfig limitsCfg;
        uint256 tokenAmount;     // for LP (0 = manual)
        uint256 amountTokenMin;  // for LP
        uint256 amountETHMin;    // for LP
        uint deadline;           // for LP
    }

    function launchWithConfig(LaunchParams memory p)
        external
        payable
        returns (address tokenAddr, address lpPair)
    {
        if (p.tokenAmount > 0 && msg.value > 0) {
            // Stealth (auto LP + trading enabled)
            (tokenAddr, lpPair) = launchStealth(
                p.name,
                p.symbol,
                p.supply,
                p.taxWallet,
                p.treasury,
                p.decayCfg,
                p.limitsCfg,
                p.tokenAmount,
                p.amountTokenMin,
                p.amountETHMin,
                p.deadline
            );
        } else {
            // Manual (just deploy)
            tokenAddr = launchManual(
                p.name,
                p.symbol,
                p.supply,
                p.taxWallet,
                p.treasury,
                p.decayCfg,
                p.limitsCfg
            );
        }
    }
}
