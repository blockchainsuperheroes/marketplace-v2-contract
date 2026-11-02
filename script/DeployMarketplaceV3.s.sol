// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PentagonMarketplaceV3} from "../src/MarketplaceV3.sol";

/// Deploys MarketplaceV3, allows the launch collections, registers known creator royalties, pauses
/// nothing, then hands ownership to OWNER (two-step: OWNER must call acceptOwnership()). The
/// broadcaster is a throwaway that holds ownership only for the duration of this script.
///   TIP_JAR=0x… COLLECTIONS=0xA,0xB [ROYALTY_COLLECTIONS=0xA ROYALTY_RECEIVERS=0x… ROYALTY_BPS_LIST=500]
///   forge script script/DeployMarketplaceV3.s.sol --rpc-url <eth> --broadcast --verify
contract DeployMarketplaceV3 is Script {
    function run() external {
        address owner = vm.envOr("OWNER", address(0xB2e3e82a95f5c4c47E30A5b420Ac4f99d32EF61f));
        address tipJar = vm.envAddress("TIP_JAR");
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(100)));
        uint16 royaltyBps = uint16(vm.envOr("DEFAULT_ROYALTY_BPS", uint256(50)));
        address[] memory collections = vm.envOr("COLLECTIONS", ",", new address[](0));
        address[] memory rc = vm.envOr("ROYALTY_COLLECTIONS", ",", new address[](0));
        address[] memory rr = vm.envOr("ROYALTY_RECEIVERS", ",", new address[](0));
        uint256[] memory rb = vm.envOr("ROYALTY_BPS_LIST", ",", new uint256[](0));
        require(rc.length == rr.length && rr.length == rb.length, "royalty lists differ in length");

        vm.startBroadcast();
        address deployer = msg.sender;
        PentagonMarketplaceV3 m = new PentagonMarketplaceV3(deployer, tipJar, feeBps, royaltyBps);
        for (uint256 i; i < collections.length; ++i) m.setCollectionAllowed(collections[i], true);
        for (uint256 i; i < rc.length; ++i) m.registerRoyalty(rc[i], rr[i], uint16(rb[i]));
        m.transferOwnership(owner);
        vm.stopBroadcast();

        console2.log("MarketplaceV3", address(m));
        console2.log("owner (until accepted)", m.owner());
        console2.log("pendingOwner", m.pendingOwner());
        console2.log("tipJar", m.tipJar());
        console2.log("guardian (none until set)", m.guardian());
        console2.log("feeBps", m.feeBps());
        console2.log("defaultRoyaltyBps", m.defaultRoyaltyBps());
        console2.log("collections allowed", collections.length);
    }
}
