// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PentagonAuctionHouse} from "../src/AuctionHouse.sol";

contract DeployAuctionHouse is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        PentagonAuctionHouse house = new PentagonAuctionHouse();
        console.log("PentagonAuctionHouse deployed at:", address(house));
        vm.stopBroadcast();
    }
}
