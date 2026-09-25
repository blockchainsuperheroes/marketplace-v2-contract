// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {PentagonVaultDrops} from "../src/VaultDrops.sol";

/// Deploys a NEW implementation only. Activating it is ProxyAdmin.upgradeAndCall(proxy, impl, "")
/// signed by the ProxyAdmin owner (0xB2e3) — the deployer can't upgrade anything.
contract DeployVaultDropsImpl is Script {
    function run() external {
        vm.startBroadcast();
        PentagonVaultDrops impl = new PentagonVaultDrops();
        vm.stopBroadcast();
        console2.log("new implementation", address(impl));
    }
}
