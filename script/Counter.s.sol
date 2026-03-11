// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {LongTailHookV4} from "../src/LongTailHookV4.sol";

/// @notice Example deployment script for LongTailHookV4 with a real v4 PoolManager.
contract LongTailHookV4Script is Script {
    LongTailHookV4 public hook;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // NOTE: replace with the actual PoolManager address when deploying against a real v4 instance.
        IPoolManager poolManager = IPoolManager(address(0xDEAD));
        hook = new LongTailHookV4(poolManager, msg.sender);

        vm.stopBroadcast();
    }
}

