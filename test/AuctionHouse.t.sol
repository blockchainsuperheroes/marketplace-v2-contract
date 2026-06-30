// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PentagonAuctionHouse} from "../src/AuctionHouse.sol";

// Minimal mocks (no OZ full impls — keeps tests on the project's pinned solc 0.8.20).
contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function safeTransferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "wrong owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        ownerOf[id] = to;
        if (to.code.length > 0) {
            require(
                IERC721ReceiverLite(to).onERC721Received(msg.sender, from, id, "") == 0x150b7a02,
                "receiver rejected"
            );
        }
    }
}

interface IERC721ReceiverLite {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract AuctionHouseTest is Test {
    PentagonAuctionHouse house;
    MockNFT nft;
    MockToken wpc;

    address seller = makeAddr("seller");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant TID = 1;

    function setUp() public {
        house = new PentagonAuctionHouse(); // owner = this contract
        nft = new MockNFT();
        wpc = new MockToken();
        house.whitelistCollection(address(nft), true);
        house.setMarketplaceFee(address(nft), 250); // 2.5%
        nft.mint(seller, TID);
        vm.prank(seller);
        nft.setApprovalForAll(address(house), true);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _createNative() internal returns (uint256 id) {
        vm.prank(seller);
        id = house.createAuction(address(nft), TID, 1 ether, 1 days, 0, address(0));
    }

    function _endTime(uint256 id) internal view returns (uint64 endTime) {
        (, , , , , endTime, , , , ) = house.auctions(id);
    }

    function testCreateEscrowsNft() public {
        _createNative();
        assertEq(nft.ownerOf(TID), address(house));
    }

    function testBidOutbidRefundsPrevious() public {
        uint256 id = _createNative();
        vm.prank(alice);
        house.bid{value: 1 ether}(id, 0);
        assertEq(alice.balance, 99 ether);

        vm.prank(bob);
        house.bid{value: 1.5 ether}(id, 0);
        assertEq(alice.balance, 100 ether); // refunded on outbid
        assertEq(bob.balance, 98.5 ether);
        assertEq(house.minNextBid(id), 1.5 ether + 0.01 ether);
    }

    function testRevertBidTooLow() public {
        uint256 id = _createNative();
        vm.prank(alice);
        vm.expectRevert(bytes("Bid too low"));
        house.bid{value: 0.5 ether}(id, 0);
    }

    function testSoftCloseExtends() public {
        uint256 id = _createNative();
        uint64 before = _endTime(id);
        vm.warp(uint256(before) - 5 minutes);
        vm.prank(alice);
        house.bid{value: 1 ether}(id, 0);
        assertGt(_endTime(id), before);
    }

    function testSettlePaysSellerMinusFee() public {
        uint256 id = _createNative();
        vm.prank(bob);
        house.bid{value: 2 ether}(id, 0);
        vm.warp(uint256(_endTime(id)) + 1);
        house.settleAuction(id);

        // fee = 2.5% of 2 = 0.05; rebate 40/40 of fee → buyer 0.02, seller 0.02, platform 0.01
        assertEq(nft.ownerOf(TID), bob);
        assertEq(seller.balance, 1.97 ether);          // 2 - 0.05 fee + 0.02 seller rebate
        assertEq(bob.balance, 98.02 ether);            // paid 2 (→98), +0.02 winner rebate
        assertEq(address(house).balance, 0.01 ether);  // platform keeps 20% of fee
    }

    function testNoBidReturnsNftToSeller() public {
        uint256 id = _createNative();
        vm.warp(uint256(_endTime(id)) + 1);
        house.settleAuction(id);
        assertEq(nft.ownerOf(TID), seller);
    }

    function testSellerCancelNoBids() public {
        uint256 id = _createNative();
        vm.prank(seller);
        house.cancelAuction(id);
        assertEq(nft.ownerOf(TID), seller);
    }

    function testRevertCancelWithBids() public {
        uint256 id = _createNative();
        vm.prank(alice);
        house.bid{value: 1 ether}(id, 0);
        vm.prank(seller);
        vm.expectRevert(bytes("Has bids"));
        house.cancelAuction(id);
    }

    function testErc20Auction() public {
        nft.mint(seller, 2);
        vm.prank(seller);
        uint256 id = house.createAuction(address(nft), 2, 1 ether, 1 days, 0, address(wpc));

        wpc.mint(bob, 10 ether);
        vm.startPrank(bob);
        wpc.approve(address(house), 10 ether);
        house.bid(id, 2 ether);
        vm.stopPrank();

        vm.warp(uint256(_endTime(id)) + 1);
        house.settleAuction(id);
        assertEq(nft.ownerOf(2), bob);
        assertEq(wpc.balanceOf(seller), 1.97 ether);        // minus fee + seller rebate
        assertEq(wpc.balanceOf(bob), 8.02 ether);           // 10 - 2 bid + 0.02 winner rebate
        assertEq(wpc.balanceOf(address(house)), 0.01 ether); // platform keeps 20% of fee
    }

    function testIncreaseBidKeepsPosition() public {
        uint256 id = _createNative();
        vm.prank(alice);
        house.bid{value: 1 ether}(id, 0);
        vm.prank(alice);
        house.increaseBid{value: 1 ether}(id, 0);
        assertEq(house.minNextBid(id), 2 ether + 0.01 ether);
        assertEq(alice.balance, 98 ether);
    }
}
