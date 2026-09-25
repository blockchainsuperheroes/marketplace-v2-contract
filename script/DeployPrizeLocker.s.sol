// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PentagonPrizeLocker} from "../src/PrizeLocker.sol";

/// Deploys the NON-upgradeable Ethereum prize lock. The broadcaster is a throwaway and gets no role
/// unless passed as KEEPER. Defaults: admin = treasury hardware wallet, depositor = prize wallet.
///   KEEPER=0x… forge script script/DeployPrizeLocker.s.sol --rpc-url <eth> --broadcast
contract DeployPrizeLocker is Script {
    function run() external {
        address admin = vm.envOr("ADMIN", address(0xB2e3e82a95f5c4c47E30A5b420Ac4f99d32EF61f));
        address depositor = vm.envOr("DEPOSITOR", address(0x1D187Aa2832cC7a3F778B075eEd0268744D3017a));
        address keeper = vm.envAddress("KEEPER");
        vm.startBroadcast();
        PentagonPrizeLocker locker = new PentagonPrizeLocker(admin, keeper, depositor);
        vm.stopBroadcast();
        console2.log("PrizeLocker", address(locker));
        console2.log("admin", locker.admin());
        console2.log("keeper", locker.keeper());
        console2.log("depositor", locker.depositor());
    }
}
