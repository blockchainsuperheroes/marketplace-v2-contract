// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {PentagonVaultDrops} from "../src/VaultDrops.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// Deploys PentagonVaultDrops behind a TransparentUpgradeableProxy on Pentagon (3344).
/// The broadcaster is a THROWAWAY: contract ownership and upgrade rights (ProxyAdmin owner) both go
/// to OWNER in these same transactions, so the deployer holds no authority afterwards.
///   OWNER=0xB2e3e82a95f5c4c47E30A5b420Ac4f99d32EF61f forge script script/DeployVaultDrops.s.sol \
///     --rpc-url pentagon --broadcast --use 0.8.24 --evm-version shanghai
contract DeployVaultDrops is Script {
    function run() external {
        address owner = vm.envOr("OWNER", address(0xB2e3e82a95f5c4c47E30A5b420Ac4f99d32EF61f));
        vm.startBroadcast();
        PentagonVaultDrops impl = new PentagonVaultDrops();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), owner, abi.encodeCall(PentagonVaultDrops.initialize, (owner))
        );
        vm.stopBroadcast();
        address admin = address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT))));
        PentagonVaultDrops vd = PentagonVaultDrops(payable(address(proxy)));
        require(vd.owner() == owner, "owner not set");
        console2.log("PROXY (use this address)", address(proxy));
        console2.log("implementation", address(impl));
        console2.log("ProxyAdmin (owner = upgrade authority)", admin);
        console2.log("owner", vd.owner());
    }
}
