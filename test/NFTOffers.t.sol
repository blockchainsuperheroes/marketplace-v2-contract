// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PentagonNFTOffers} from "../src/NFTOffers.sol";

interface IERC721ReceiverLite {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    address public royaltyReceiver;
    uint256 public royaltyBps;

    function mint(address to, uint256 id) external { ownerOf[id] = to; }
    function setApprovalForAll(address op, bool ok) external { isApprovedForAll[msg.sender][op] = ok; }
    function setRoyalty(address r, uint256 bps) external { royaltyReceiver = r; royaltyBps = bps; }

    function royaltyInfo(uint256, uint256 price) external view returns (address, uint256) {
        return (royaltyReceiver, (price * royaltyBps) / 10000);
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

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

contract NFTOffersTest is Test {
    PentagonNFTOffers off;
    MockNFT nft;
    MockERC20 wpc;
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address other = makeAddr("other");
    address royalty = makeAddr("royalty");

    function setUp() public {
        off = new PentagonNFTOffers(); // owner = this
        nft = new MockNFT();
        wpc = new MockERC20();
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(address(off), true);
        vm.deal(buyer, 100 ether);
        vm.deal(other, 100 ether);
    }

    function _native(uint256 price) internal returns (uint256 id) {
        vm.prank(buyer);
        id = off.makeOffer{value: price}(address(nft), 1, price, address(0), 1 days);
    }

    // ─── Native PC offers ───────────────────────────────────────────────────
    function testMakeOfferEscrowsNative() public {
        uint256 id = _native(2 ether);
        assertEq(address(off).balance, 2 ether); // escrowed
        assertEq(buyer.balance, 98 ether);
        assertTrue(off.isLive(id));
    }

    function testCannotOfferOnOwnToken() public {
        vm.deal(seller, 5 ether);
        vm.prank(seller);
        vm.expectRevert(bytes("Own token"));
        off.makeOffer{value: 1 ether}(address(nft), 1, 1 ether, address(0), 1 days);
    }

    function testWrongNativeValueReverts() public {
        vm.prank(buyer);
        vm.expectRevert(bytes("Wrong native value"));
        off.makeOffer{value: 1 ether}(address(nft), 1, 2 ether, address(0), 1 days);
    }

    function testAcceptPaysSellerMinusFee() public {
        uint256 id = _native(2 ether);
        vm.prank(seller);
        off.acceptOffer(id);
        // fee 2.5% = 0.05; no royalty → seller gets 1.95
        assertEq(nft.ownerOf(1), buyer);
        assertEq(seller.balance, 1.95 ether);
        assertEq(off.feesAccrued(address(0)), 0.05 ether);
        assertEq(address(off).balance, 0.05 ether); // only fee remains
    }

    function testAcceptHonorsRoyalty() public {
        nft.setRoyalty(royalty, 500); // 5%
        uint256 id = _native(2 ether);
        vm.prank(seller);
        off.acceptOffer(id);
        // price 2: fee 0.05, royalty 0.10 → seller 1.85
        assertEq(seller.balance, 1.85 ether);
        assertEq(royalty.balance, 0.1 ether);
        assertEq(off.feesAccrued(address(0)), 0.05 ether);
    }

    function testOnlyOwnerCanAccept() public {
        uint256 id = _native(2 ether);
        vm.prank(other);
        vm.expectRevert(bytes("Not token owner"));
        off.acceptOffer(id);
    }

    function testBuyerCancelsRefunds() public {
        uint256 id = _native(2 ether);
        vm.prank(buyer);
        off.cancelOffer(id);
        assertEq(buyer.balance, 100 ether);
        assertFalse(off.isLive(id));
        vm.prank(seller);
        vm.expectRevert(bytes("Inactive"));
        off.acceptOffer(id);
    }

    function testOnlyBuyerCancels() public {
        uint256 id = _native(2 ether);
        vm.prank(other);
        vm.expectRevert(bytes("Not buyer"));
        off.cancelOffer(id);
    }

    function testExpiryBlocksAcceptAndAllowsReclaim() public {
        uint256 id = _native(2 ether);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(seller);
        vm.expectRevert(bytes("Expired"));
        off.acceptOffer(id);
        // anyone can reclaim an expired offer → buyer refunded
        vm.prank(other);
        off.reclaimExpired(id);
        assertEq(buyer.balance, 100 ether);
    }

    function testReclaimBeforeExpiryReverts() public {
        uint256 id = _native(2 ether);
        vm.expectRevert(bytes("Not expired"));
        off.reclaimExpired(id);
    }

    function testBadDurationReverts() public {
        vm.prank(buyer);
        vm.expectRevert(bytes("Bad duration"));
        off.makeOffer{value: 1 ether}(address(nft), 1, 1 ether, address(0), 1 minutes);
    }

    // ─── ERC20 (WPC) offers ─────────────────────────────────────────────────
    function testErc20OfferEscrowsAndPays() public {
        wpc.mint(buyer, 5 ether);
        vm.prank(buyer);
        wpc.approve(address(off), 2 ether);
        vm.prank(buyer);
        uint256 id = off.makeOffer(address(nft), 1, 2 ether, address(wpc), 1 days);
        assertEq(wpc.balanceOf(address(off)), 2 ether); // escrowed
        vm.prank(seller);
        off.acceptOffer(id);
        assertEq(nft.ownerOf(1), buyer);
        assertEq(wpc.balanceOf(seller), 1.95 ether);
        assertEq(off.feesAccrued(address(wpc)), 0.05 ether);
    }

    function testErc20RejectsNativeValue() public {
        wpc.mint(buyer, 5 ether);
        vm.prank(buyer);
        wpc.approve(address(off), 2 ether);
        vm.prank(buyer);
        vm.expectRevert(bytes("No native for ERC20 offer"));
        off.makeOffer{value: 1 ether}(address(nft), 1, 2 ether, address(wpc), 1 days);
    }

    // ─── Admin ────────────────────────────────────────────────────────────
    function testOwnerWithdrawsFees() public {
        uint256 id = _native(2 ether);
        vm.prank(seller);
        off.acceptOffer(id);
        uint256 before = address(this).balance;
        off.withdrawFees(address(0), 0.05 ether);
        assertEq(address(this).balance, before + 0.05 ether);
        assertEq(off.feesAccrued(address(0)), 0);
    }

    function testSetFeeGuards() public {
        vm.expectRevert(bytes("Fee too high (max 10%)"));
        off.setFee(1001);
        off.setFee(500);
        assertEq(off.marketplaceFee(), 500);
        vm.prank(other);
        vm.expectRevert();
        off.setFee(100);
    }

    receive() external payable {}
}
