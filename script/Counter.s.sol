// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {LongTailHook} from "../src/LongTailHook.sol";
import {IPoolManagerMinimal} from "../src/ILongTailHookTypes.sol";

/// @notice Example deployment script for LongTailHook.
contract LongTailHookScript is Script {
    LongTailHook public hook;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // NOTE: replace with the actual PoolManager address when deploying against a real v4 instance.
        IPoolManagerMinimal poolManager = IPoolManagerMinimal(address(0xDEAD));
        hook = new LongTailHook(poolManager, msg.sender);

        vm.stopBroadcast();
    }
}

