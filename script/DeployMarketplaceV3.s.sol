// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PentagonMarketplaceV3} from "../src/MarketplaceV3.sol";

/// Deploys MarketplaceV3, allows the launch collections, registers known creator royalties, pauses
/// nothing, then hands ownership to OWNER (two-step: OWNER must call acceptOwnership()). The
/// broadcaster is a throwaway that holds ownership only for the duration of this script.
///   TIP_JAR=0x… COLLECTIONS=0xA,0xB [ROYALTY_COLLECTIONS=0xA ROYALTY_RECEIVERS=0x… ROYALTY_BPS_LIST=500]
///   forge script script/DeployMarketplaceV3.s.sol --rpc-url <eth> --broadcast --verify
/// Signed listings (all optional; anything left out is set later by OWNER):
///   COSIGNER=0x…   the key that signs FillAuths. Unset = signed orders can't be filled yet.
///   FLAGGER=0x…    the key that flags tokens.
///   FLOOR_COLLECTIONS=0xA,0xB FLOOR_REFS_WEI=1200000000000000000,…   one-time floor reference per
///     collection (the clean floor, in wei, on deploy day). Unseeded, the first signed fill sets it from
///     the co-signer's number as given.
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
        address cosigner = vm.envOr("COSIGNER", address(0));
        address flagger = vm.envOr("FLAGGER", address(0));
        address[] memory fc = vm.envOr("FLOOR_COLLECTIONS", ",", new address[](0));
        uint256[] memory fr = vm.envOr("FLOOR_REFS_WEI", ",", new uint256[](0));
        require(fc.length == fr.length, "floor lists differ in length");
        for (uint256 i; i < fr.length; ++i) require(fr[i] != 0 && fr[i] <= type(uint128).max, "bad floor reference");

        vm.startBroadcast();
        address deployer = msg.sender;
        PentagonMarketplaceV3 m = new PentagonMarketplaceV3(deployer, tipJar, feeBps, royaltyBps);
        for (uint256 i; i < collections.length; ++i) m.setCollectionAllowed(collections[i], true);
        for (uint256 i; i < rc.length; ++i) m.registerRoyalty(rc[i], rr[i], uint16(rb[i]));
        for (uint256 i; i < fc.length; ++i) m.seedFloorRef(fc[i], uint128(fr[i]));
        if (cosigner != address(0)) m.setCosigner(cosigner);
        if (flagger != address(0)) m.setFlagger(flagger);
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
        console2.log("cosigner (0 = signed fills off)", m.cosigner());
        console2.log("flagger", m.flagger());
        console2.log("floor references seeded", fc.length);
        console2.log("floor fall / rise bps per day", m.floorFallBpsPerDay(), m.floorRiseBpsPerDay());
        console2.log("floor backstop bps", m.floorBackstopBps());
    }
}
