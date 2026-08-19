// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PentagonNFTOffers} from "../src/NFTOffers.sol";

// Deploy PentagonNFTOffers on Pentagon Chain (3344), then hand ownership to the treasury wallet.
// Usage: forge script script/DeployNFTOffers.s.sol --rpc-url https://rpc.pentagon.games \
//        --broadcast --legacy --gas-price <gp>   (PRIVATE_KEY + optional OWNER in env)
contract DeployNFTOffers is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address newOwner = vm.envOr("OWNER", address(0x2e3e82a95f5c4c47E30A5b420Ac4f99d32EF61f)); // hardware wallet placeholder — overridden by env
        vm.startBroadcast(deployerKey);
        PentagonNFTOffers offers = new PentagonNFTOffers();
        if (newOwner != address(0) && newOwner != msg.sender) {
            offers.transferOwnership(newOwner);
        }
        vm.stopBroadcast();
        console.log("PentagonNFTOffers deployed at:", address(offers));
        console.log("owner:", offers.owner());
    }
}
