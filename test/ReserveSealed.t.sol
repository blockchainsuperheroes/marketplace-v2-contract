// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PentagonReserveAuction} from "../src/ReserveAuction.sol";
import {PentagonSealedBidAuction} from "../src/SealedBidAuction.sol";

interface IERC721ReceiverLite {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external { ownerOf[id] = to; }
    function setApprovalForAll(address op, bool ok) external { isApprovedForAll[msg.sender][op] = ok; }

    function safeTransferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "wrong owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        ownerOf[id] = to;
        if (to.code.length > 0) {
            require(IERC721ReceiverLite(to).onERC721Received(msg.sender, from, id, "") == 0x150b7a02, "receiver rejected");
        }
    }
}

contract ReserveAuctionTest is Test {
    PentagonReserveAuction ra;
    MockNFT nft;
    address seller = makeAddr("seller");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bytes32 constant SALT = keccak256("salt");

    function setUp() public {
        ra = new PentagonReserveAuction();
        nft = new MockNFT();
        ra.whitelistCollection(address(nft), true);
        ra.setMarketplaceFee(address(nft), 250);
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(address(ra), true);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _hash(uint256 price) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(price, SALT));
    }

    function _create(uint256 reserve) internal returns (uint256 id) {
        vm.prank(seller);
        id = ra.createReserveAuction(address(nft), 1, 1 ether, _hash(reserve), 1 days, 0);
    }

    function _endTime(uint256 id) internal view returns (uint64 e) {
        (, , , , e, , , , , , , ) = ra.auctions(id);
    }

    function testEscrowAndOutbidRefund() public {
        uint256 id = _create(1.5 ether);
        assertEq(nft.ownerOf(1), address(ra));
        vm.prank(alice);
        ra.bid{value: 1 ether}(id);
        vm.prank(bob);
        ra.bid{value: 2 ether}(id);
        assertEq(alice.balance, 100 ether);
    }

    function testRevealGuards() public {
        uint256 id = _create(1.5 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("Not seller"));
        ra.revealReserve(id, 1.5 ether, SALT);
        vm.prank(seller);
        vm.expectRevert(bytes("Bad reveal"));
        ra.revealReserve(id, 2 ether, SALT); // wrong price
        vm.prank(seller);
        ra.revealReserve(id, 1.5 ether, SALT);
    }

    function testSettleReserveMetPaysWithRebate() public {
        uint256 id = _create(1.5 ether);
        vm.prank(bob);
        ra.bid{value: 2 ether}(id);
        vm.prank(seller);
        ra.revealReserve(id, 1.5 ether, SALT);
        vm.warp(uint256(_endTime(id)) + 1);
        ra.settleAuction(id);
        // fee 0.05; rebates 0.02/0.02; platform keeps 0.01
        assertEq(nft.ownerOf(1), bob);
        assertEq(seller.balance, 1.97 ether);
        assertEq(bob.balance, 98.02 ether);
        assertEq(address(ra).balance, 0.01 ether);
    }

    function testSettleReserveNotMetRefunds() public {
        uint256 id = _create(3 ether);
        vm.prank(bob);
        ra.bid{value: 2 ether}(id);
        vm.prank(seller);
        ra.revealReserve(id, 3 ether, SALT);
        vm.warp(uint256(_endTime(id)) + 1);
        ra.settleAuction(id);
        assertEq(nft.ownerOf(1), seller); // NFT home
        assertEq(bob.balance, 100 ether); // fully refunded
    }

    function testSettleNeverRevealedRefunds() public {
        uint256 id = _create(1.5 ether);
        vm.prank(bob);
        ra.bid{value: 2 ether}(id);
        vm.warp(uint256(_endTime(id)) + 1);
        ra.settleAuction(id); // seller never revealed
        assertEq(nft.ownerOf(1), seller);
        assertEq(bob.balance, 100 ether);
    }

    function testCancelNoBidsOnly() public {
        uint256 id = _create(1.5 ether);
        vm.prank(alice);
        ra.bid{value: 1 ether}(id);
        vm.prank(seller);
        vm.expectRevert(bytes("Has bids"));
        ra.cancelAuction(id);
    }
}

contract SealedBidAuctionTest is Test {
    PentagonSealedBidAuction sa;
    MockNFT nft;
    address seller = makeAddr("seller");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bytes32 constant SALT_A = keccak256("a");
    bytes32 constant SALT_B = keccak256("b");

    function setUp() public {
        sa = new PentagonSealedBidAuction();
        nft = new MockNFT();
        sa.whitelistCollection(address(nft), true);
        sa.setMarketplaceFee(address(nft), 250);
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(address(sa), true);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _commitment(uint256 amount, bytes32 salt, address bidder) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(amount, salt, bidder));
    }

    function _create() internal returns (uint256 id) {
        vm.prank(seller);
        id = sa.createSealedAuction(address(nft), 1, 1 ether, 1 days, 1 days);
    }

    function _phases(uint256 id) internal view returns (uint64 commitEnd, uint64 revealEnd) {
        (, , , , commitEnd, revealEnd, , , ) = sa.auctions(id);
    }

    function testCommitRevealSettleWithMaskedDeposit() public {
        uint256 id = _create();
        // bob true bid 1.5, masks with deposit 2; alice true bid 2, masks with 3
        vm.prank(bob);
        sa.commitBid{value: 2 ether}(id, _commitment(1.5 ether, SALT_B, bob));
        vm.prank(alice);
        sa.commitBid{value: 3 ether}(id, _commitment(2 ether, SALT_A, alice));

        (uint64 commitEnd, uint64 revealEnd) = _phases(id);
        vm.warp(commitEnd);
        vm.prank(bob);
        sa.revealBid(id, 1.5 ether, SALT_B); // leads
        vm.prank(alice);
        sa.revealBid(id, 2 ether, SALT_A); // displaces bob → bob fully refunded
        assertEq(bob.balance, 100 ether);

        vm.warp(revealEnd);
        sa.settleAuction(id);
        // price 2: fee .05, rebates .02/.02 → seller 1.97; alice back excess 1 + .02
        assertEq(nft.ownerOf(1), alice);
        assertEq(seller.balance, 1.97 ether);
        assertEq(alice.balance, 98.02 ether);
        assertEq(address(sa).balance, 0.01 ether);
    }

    function testRevealGuards() public {
        uint256 id = _create();
        vm.prank(alice);
        sa.commitBid{value: 2 ether}(id, _commitment(2 ether, SALT_A, alice));
        (uint64 commitEnd, uint64 revealEnd) = _phases(id);
        vm.prank(alice);
        vm.expectRevert(bytes("Commit phase running"));
        sa.revealBid(id, 2 ether, SALT_A);
        vm.warp(commitEnd);
        vm.prank(alice);
        vm.expectRevert(bytes("Bad reveal"));
        sa.revealBid(id, 2 ether, SALT_B); // wrong salt
        vm.warp(revealEnd);
        vm.prank(alice);
        vm.expectRevert(bytes("Reveal phase over"));
        sa.revealBid(id, 2 ether, SALT_A);
    }

    function testBidExceedingDepositRejected() public {
        uint256 id = _create();
        vm.prank(alice);
        sa.commitBid{value: 1 ether}(id, _commitment(2 ether, SALT_A, alice));
        (uint64 commitEnd, ) = _phases(id);
        vm.warp(commitEnd);
        vm.prank(alice);
        vm.expectRevert(bytes("Bid exceeds deposit"));
        sa.revealBid(id, 2 ether, SALT_A);
    }

    function testUnrevealedReclaim() public {
        uint256 id = _create();
        vm.prank(alice);
        sa.commitBid{value: 2 ether}(id, _commitment(1.5 ether, SALT_A, alice));
        (, uint64 revealEnd) = _phases(id);
        vm.prank(alice);
        vm.expectRevert(bytes("Reveal phase running"));
        sa.reclaimDeposit(id);
        vm.warp(revealEnd);
        vm.prank(alice);
        sa.reclaimDeposit(id);
        assertEq(alice.balance, 100 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("Already refunded"));
        sa.reclaimDeposit(id);
    }

    function testNoRevealsReturnsNft() public {
        uint256 id = _create();
        vm.prank(alice);
        sa.commitBid{value: 2 ether}(id, _commitment(1.5 ether, SALT_A, alice));
        (, uint64 revealEnd) = _phases(id);
        vm.warp(revealEnd);
        sa.settleAuction(id);
        assertEq(nft.ownerOf(1), seller);
    }

    function testCancelDuringCommitUnlocksReclaims() public {
        uint256 id = _create();
        vm.prank(alice);
        sa.commitBid{value: 2 ether}(id, _commitment(1.5 ether, SALT_A, alice));
        vm.prank(seller);
        sa.cancelAuction(id, 1);
        assertEq(nft.ownerOf(1), seller);
        vm.prank(alice);
        sa.reclaimDeposit(id); // revealEnd pulled to now → reclaim opens
        assertEq(alice.balance, 100 ether);
    }
}
