// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract KitchenTimelock {
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    mapping(bytes32 => uint256) public timelockQueue;

    event TimelockQueued(bytes32 indexed actionHash, uint256 executeAfter);
    event TimelockExecuted(bytes32 indexed actionHash);

    modifier timelocked(bytes32 actionHash) {
        uint256 executeAfter = timelockQueue[actionHash];
        require(executeAfter != 0 && block.timestamp >= executeAfter, "Timelock: not ready");
        _;
        emit TimelockExecuted(actionHash);
        delete timelockQueue[actionHash];
    }

    function queueAction(bytes32 actionHash) external {
        timelockQueue[actionHash] = block.timestamp + TIMELOCK_DELAY;
        emit TimelockQueued(actionHash, timelockQueue[actionHash]);
    }
}
