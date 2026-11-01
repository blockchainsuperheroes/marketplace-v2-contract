// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RedeemReleaseAdmin} from "../src/RedeemReleaseAdmin.sol";

/// Deploys the auto-release admin for the two Ethereum prize lockers. Nothing changes until HUMAN signs
/// proposeRoles(admin = this contract) on each locker and the 48h delay passes. No owner, no upgrade.
///   VERIFIER=0x… forge script script/DeployRedeemReleaseAdmin.s.sol --rpc-url <eth> --broadcast --verify
contract DeployRedeemReleaseAdmin is Script {
    function run() external {
        address human = vm.envOr("HUMAN", address(0xB2e3e82a95f5c4c47E30A5b420Ac4f99d32EF61f));
        address verifier = vm.envAddress("VERIFIER");
        address lockerOpen = vm.envOr("LOCKER_OPEN", address(0x1AFc17a1B64Cb7095d68CD360e4766f951983aB9));
        address lockerOwn = vm.envOr("LOCKER_OWN", address(0x7c0faC2561471A9810a5609e6FeD86af0A6d0924));
        vm.startBroadcast();
        RedeemReleaseAdmin ra = new RedeemReleaseAdmin(human, verifier, lockerOpen, lockerOwn);
        vm.stopBroadcast();
        console2.log("RedeemReleaseAdmin", address(ra));
        console2.log("human", ra.human());
        console2.log("verifier", ra.verifier());
    }
}
