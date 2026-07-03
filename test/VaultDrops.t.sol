// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PentagonVaultDrops} from "../src/VaultDrops.sol";

contract VaultDropsTest is Test {
    PentagonVaultDrops vd;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    // prize ref: BCSH ETH #42 on Ethereum
    uint64 constant PRIZE_CHAIN = 1;
    address constant PRIZE_CONTRACT = 0x67abaDDb1258077F7900abD8AdE0EcC6CdC38ac2;

    function setUp() public {
        vd = new PentagonVaultDrops(); // owner = this; treasury defaults to owner
        vd.setConfig(5000, treasury, 7 days);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _create() internal returns (uint256 id) {
        id = vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 42, 1 ether, 1 days, 0);
    }

    function _endTime(uint256 id) internal view returns (uint64 endTime) {
        (, , , , endTime, , , , , , ) = vd.drops(id);
    }

    function testOnlyOwnerCreates() public {
        vm.prank(alice);
        vm.expectRevert();
        vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 42, 1 ether, 1 days, 0);
    }

    function testBidOutbidRefund() public {
        uint256 id = _create();
        vm.prank(alice);
        vd.bid{value: 1 ether}(id);
        vm.prank(bob);
        vd.bid{value: 1.5 ether}(id);
        assertEq(alice.balance, 100 ether); // refunded instantly
        assertEq(vd.minNextBid(id), 1.5 ether + 0.01 ether);
        assertEq(address(vd).balance, 1.5 ether); // only top bid escrowed
    }

    function testSoftCloseExtends() public {
        uint256 id = _create();
        uint64 endBefore = _endTime(id);
        vm.warp(uint256(endBefore) - 5 minutes);
        vm.prank(alice);
        vd.bid{value: 1 ether}(id);
        assertGt(_endTime(id), endBefore);
    }

    function testSettleKeepsEscrowUntilFulfilled() public {
        uint256 id = _create();
        vm.prank(bob);
        vd.bid{value: 2 ether}(id);
        vm.warp(uint256(_endTime(id)) + 1);
        vd.settleDrop(id);
        // funds still escrowed — nothing paid out at settlement
        assertEq(address(vd).balance, 2 ether);
        assertEq(treasury.balance, 0);
        assertEq(BURN.balance, 0);
    }

    function testFulfillSplitsBurnTreasury() public {
        uint256 id = _create();
        vm.prank(bob);
        vd.bid{value: 2 ether}(id);
        vm.warp(uint256(_endTime(id)) + 1);
        vd.settleDrop(id);
        vd.markFulfilled(id, bytes32(uint256(0xbeef)));
        assertEq(BURN.balance, 1 ether); // 50% burned — the PC sink
        assertEq(treasury.balance, 1 ether); // 50% treasury
        assertEq(address(vd).balance, 0);
    }

    function testReclaimAfterWindowRefundsWinner() public {
        uint256 id = _create();
        vm.prank(bob);
        vd.bid{value: 2 ether}(id);
        vm.warp(uint256(_endTime(id)) + 1);
        vd.settleDrop(id);
        // too early
        vm.prank(bob);
        vm.expectRevert(bytes("Fulfill window open"));
        vd.reclaimBid(id);
        // after the window — full refund
        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        vd.reclaimBid(id);
        assertEq(bob.balance, 100 ether);
        // and fulfillment is now blocked
        vm.expectRevert(bytes("Reclaimed"));
        vd.markFulfilled(id, bytes32(0));
    }

    function testFulfillBlocksReclaim() public {
        uint256 id = _create();
        vm.prank(bob);
        vd.bid{value: 2 ether}(id);
        vm.warp(uint256(_endTime(id)) + 1);
        vd.settleDrop(id);
        vd.markFulfilled(id, bytes32(uint256(1)));
        vm.warp(block.timestamp + 30 days);
        vm.prank(bob);
        vm.expectRevert(bytes("Fulfilled"));
        vd.reclaimBid(id);
    }

    function testCancelOnlyWithoutBids() public {
        uint256 id = _create();
        vd.cancelDrop(id); // ok, no bids
        uint256 id2 = _create();
        vm.prank(alice);
        vd.bid{value: 1 ether}(id2);
        vm.expectRevert(bytes("Has bids"));
        vd.cancelDrop(id2);
    }

    function testNoBidSettleIsClean() public {
        uint256 id = _create();
        vm.warp(uint256(_endTime(id)) + 1);
        vd.settleDrop(id);
        // no winner, nothing to fulfill
        vm.expectRevert(bytes("No winner"));
        vd.markFulfilled(id, bytes32(0));
    }

    function testConfigGuards() public {
        vm.expectRevert(bytes("burnBps > 100%"));
        vd.setConfig(10001, treasury, 7 days);
        vm.expectRevert(bytes("Bad window"));
        vd.setConfig(5000, treasury, 12 hours);
        vm.prank(alice);
        vm.expectRevert();
        vd.setConfig(5000, treasury, 7 days);
    }
}
