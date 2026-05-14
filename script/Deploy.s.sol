// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MarketplaceV2.sol";

contract DeployMarketplaceV2 is Script {
    // Pentagon Chain collections
    address constant SETSUKO = 0xcDAD57bFc48E8373280C6dc3039C5169353B6879;
    address constant JEWELRY = 0xc05b96b89Ce46c306223E3f4c413891d17E1De70;
    address constant GUNNIES_PFP = 0x7a8a3236e3783E7cC33b97729378e31Cf14d3Ebc;
    address constant EF_GENESIS = 0x8F83c6122Dd4d275B53a7846B3D3dB29Cca1e698;
    address constant RUGPULL = 0xD77f88ef51b2589D132D6eb61068079F61Dfe4A3;

    uint256 constant FEE_250_BPS = 250; // 2.5%

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        PentagonMarketplaceV2 marketplace = new PentagonMarketplaceV2();

        // Whitelist all collections
        marketplace.whitelistCollection(SETSUKO, true);
        marketplace.whitelistCollection(JEWELRY, true);
        marketplace.whitelistCollection(GUNNIES_PFP, true);
        marketplace.whitelistCollection(EF_GENESIS, true);
        marketplace.whitelistCollection(RUGPULL, true);

        // Set 2.5% fee on each
        marketplace.setMarketplaceFee(SETSUKO, FEE_250_BPS);
        marketplace.setMarketplaceFee(JEWELRY, FEE_250_BPS);
        marketplace.setMarketplaceFee(GUNNIES_PFP, FEE_250_BPS);
        marketplace.setMarketplaceFee(EF_GENESIS, FEE_250_BPS);
        marketplace.setMarketplaceFee(RUGPULL, FEE_250_BPS);

        vm.stopBroadcast();

        console.log("MarketplaceV2 deployed at:", address(marketplace));
    }
}
