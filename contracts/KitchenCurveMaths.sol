// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title KitchenCurveMaths
 * @notice Virtual Uniswap-style bonding curve (x * y = k) with a +1 ETH virtual reserve.
 *         getTokensForEth / getEthForTokens are consistent with the +1 ETH model.
 */
library KitchenCurveMaths {
    uint256 internal constant VIRTUAL_ETH = 1 ether;

    /**
     * @notice Calculate tokens bought for a given ETH input on the virtual curve.
     * @dev Adds +1 virtual ETH to simulate initial reserve and prevent zero-division/exploits.
     */
    function getTokensForEth(
        uint256 totalSupply,
        uint256 ethRaised,
        uint256 tokensSold,
        uint256 ethIn
    ) internal pure returns (uint256 tokensOut) {
    // totalSupply: curve's virtual total supply (genesis)
    // ethRaised: ETH accumulated so far on the curve
    // tokensSold: circulating tokens minted/issued so far
    // ethIn: incoming ETH for this buy operation
        require(ethIn > 0, "No ETH sent");
        require(tokensSold < totalSupply, "Sold out");

    // tokenReserve & ethReserve implement the virtual x*y=k invariant
    // adding VIRTUAL_ETH prevents zero-division when ethRaised==0.
    uint256 tokenReserve = totalSupply - tokensSold;
    uint256 ethReserve   = ethRaised + VIRTUAL_ETH;
    uint256 k            = tokenReserve * ethReserve;

    // After adding ethIn to the ETH side, derive the new token reserve from k
    uint256 newEthReserve   = ethReserve + ethIn;
    uint256 newTokenReserve = k / newEthReserve;

    // tokensOut is the delta in token reserve consumed by this buy
    tokensOut = tokenReserve - newTokenReserve;
        return tokensOut;
    }

    /**
     * @notice Calculate ETH output for a given token sellback on the curve.
     * @dev Adds +1 virtual ETH to simulate consistent pricing behavior and graduation match.
     */
    function getEthForTokens(
        uint256 totalSupply,
        uint256 ethRaised,
        uint256 tokensSold,
        uint256 tokenIn
    ) internal pure returns (uint256 ethOut) {
    // Reverse of getTokensForEth: used for quoting sellbacks
    // trivial cases
    if (tokenIn == 0 || tokensSold == 0) return 0;

    // Correct invariant for sells:
    // You can’t sell more than what’s currently in circulation.
    require(tokenIn <= tokensSold, "Over-sell");

    uint256 tokenReserve = totalSupply - tokensSold;
    uint256 ethReserve   = ethRaised + VIRTUAL_ETH;
    uint256 k            = tokenReserve * ethReserve;

    // Adding tokens back to the token reserve reduces ETH reserve by ratio
    uint256 newTokenReserve = tokenReserve + tokenIn;
    uint256 newEthReserve   = k / newTokenReserve;

    // ethOut is the ETH that will be released to the seller
    ethOut = ethReserve - newEthReserve;
        return ethOut;
    }

    /**
     * @notice ETH that would be in the pool if circulating supply were `supply` (from genesis with +1 ETH model).
     * @dev Inverts the closed form: tokensOut = ts * ethIn / (VIRTUAL_ETH + ethIn).
     *      => ethIn = (supply * VIRTUAL_ETH) / (ts - supply)
     */
    function ethAtSupplyFromGenesis(
        uint256 totalSupply,
        uint256 supply
    ) internal pure returns (uint256 ethRaised) {
        require(supply > 0 && supply < totalSupply, "bad supply");
    // Closed-form inversion of the +1 ETH curve model. Given a desired
    // circulating `supply`, compute how much ETH would exist in the pool
    // at that point starting from genesis accounting for VIRTUAL_ETH.
    ethRaised = (supply * VIRTUAL_ETH) / (totalSupply - supply);
    }

    /**
     * @notice Marginal price (wei per 1e18 tokens) at a given `supply` from genesis with +1 ETH model.
     */
    function marginalPriceAt(
        uint256 totalSupply,
        uint256 supply
    ) internal pure returns (uint256 weiPer1e18) {
        if (supply == 0 || supply >= totalSupply) return 0;
        uint256 ethAtSupply = ethAtSupplyFromGenesis(totalSupply, supply);
        // price = ETH for 1e18 delta at that point
        return getEthForTokens(totalSupply, ethAtSupply, supply, 1e18);
    }

    /**
     * @notice Final price (ETH/token) of the last buy in curve simulation (unscaled).
     * @dev Kept for backward compatibility where used in step sims.
     */
    function getFinalPrice(uint256 ethStep, uint256 tokensBought) internal pure returns (uint256) {
        require(tokensBought > 0, "Zero tokens");
        return ethStep / tokensBought;
    }

    /**
     * @notice Calculates how many tokens to pair with `ethRaised` in LP to preserve curve price.
     * @dev `finalCurvePrice` is wei per 1e18 (same scale as Utils.getVirtualPrice()).
     */
    function getTokensToLP(
        uint256 ethRaised,
        uint256 finalCurvePrice
    ) internal pure returns (uint256) {
        require(finalCurvePrice > 0, "Zero price");
    // Compute number of tokens that preserve the curve marginal price when
    // pairing `ethRaised` into liquidity. finalCurvePrice uses wei per 1e18.
    return (ethRaised * 1e18) / finalCurvePrice;
    }

    /* Optional helper left as-is; not used by current flow */
    function computeEthToRaise(
        uint256 totalSupply,
        uint256 startingVirtualEth,
        uint256 targetPrice,
        uint256 ethPrice
    ) internal pure returns (uint256 ethRaised) {
        require(ethPrice > 0, "ETH price must be >0");
        require(targetPrice > startingVirtualEth, "Target must exceed start");

    // Helper for simulation: estimate ETH required to reach a target price
    // given starting virtual ETH using a heuristic closed-form (kept for
    // simulation/testing; not used in main flows).
    uint256 numerator = totalSupply * (targetPrice - startingVirtualEth);
    ethRaised = sqrt(numerator / ethPrice);
        return ethRaised;
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
