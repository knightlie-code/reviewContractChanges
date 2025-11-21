// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./KitchenTimelock.sol";
import "./vendor/chainlink/AggregatorV3Interface.sol";

contract KitchenOracles is KitchenTimelock {
    address public owner;

    AggregatorV3Interface public ethUsdFeed; // 8 decimals
    AggregatorV3Interface public gasFeed;    // Gas price feed (gwei units in answer)

    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event FeedsUpdated(address ethUsd, address gas);

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor(address _ethUsd, address _gas) {
        owner = msg.sender;
        ethUsdFeed = AggregatorV3Interface(_ethUsd);
        gasFeed    = AggregatorV3Interface(_gas);
    }

    function transferOwnership(address n)
        external
        onlyOwner
        timelocked(keccak256("ORACLE_OWNER"))
    {
        require(n != address(0), "Zero");
        emit OwnerTransferred(owner, n);
        owner = n;
    }

    function setFeeds(address _ethUsd, address _gas)
        external
        onlyOwner
        timelocked(keccak256("ORACLE_FEEDS"))
    {
        ethUsdFeed = AggregatorV3Interface(_ethUsd);
        gasFeed    = AggregatorV3Interface(_gas);
        emit FeedsUpdated(_ethUsd, _gas);
    }

    /// @notice ETH price in USD with 8 decimals
    function ethUsd() public view returns (uint256 price, uint256 updatedAt) {
        // (roundId, answer, startedAt, updatedAt, answeredInRound)
        (, int256 answer,, uint256 updated,) = ethUsdFeed.latestRoundData();
        require(answer > 0, "Bad ETH/USD");
        return (uint256(answer), updated);
    }

    /// @notice Fast gas price in WEI (convert from gwei provided by the feed)
    function gasWei() public view returns (uint256 weiPrice, uint256 updatedAt) {
        // (roundId, answer, startedAt, updatedAt, answeredInRound)
        (, int256 gasPriceGwei,, uint256 updated,) = gasFeed.latestRoundData();
        require(gasPriceGwei > 0, "Bad gas");
        return (uint256(gasPriceGwei) * 1_000_000_000, updated); // gwei → wei
    }
}

