// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PentagonMarketplaceV3} from "../src/MarketplaceV3.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract MockNFT is ERC721 {
    constructor(string memory n) ERC721(n, n) {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract OwnedNFT is ERC721 {
    address public owner;
    constructor(address o) ERC721("O", "O") { owner = o; }
    function mint(address to, uint256 id) external { _mint(to, id); }
}

/// A seller wallet that rejects payments until told to accept them (e.g. a smart wallet with no receive()).
contract PickySeller {
    bool public accept;
    function setAccept(bool a) external { accept = a; }
    function approve(ERC721 nft, address op) external { nft.setApprovalForAll(op, true); }
    function list(PentagonMarketplaceV3 m, address c, uint256 id, uint256 price) external {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        ids[0] = id;
        prices[0] = price;
        m.list(c, ids, prices, block.timestamp + 1 days);
    }
    function withdraw(PentagonMarketplaceV3 m) external { m.withdraw(); }
    receive() external payable { require(accept, "no"); }
}

contract MarketplaceV3Test is Test {
    PentagonMarketplaceV3 m;
    MockNFT a;
    MockNFT b;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address floorFund = makeAddr("floorFund");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address buyer = makeAddr("buyer");
    address creator = makeAddr("creator");

    function setUp() public {
        m = new PentagonMarketplaceV3(owner, treasury, floorFund, 250, 250);
        a = new MockNFT("A");
        b = new MockNFT("B");
        vm.startPrank(owner);
        m.setCollectionAllowed(address(a), true);
        m.setCollectionAllowed(address(b), true);
        vm.stopPrank();
        for (uint256 i = 1; i <= 5; ++i) a.mint(alice, i);
        b.mint(bob, 1);
        b.mint(bob, 2);
        vm.prank(alice);
        a.setApprovalForAll(address(m), true);
        vm.prank(bob);
        b.setApprovalForAll(address(m), true);
        vm.deal(buyer, 100 ether);
    }

    // ───────── helpers ─────────

    function _list(address seller, MockNFT nft, uint256 id, uint256 price) internal {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        ids[0] = id;
        prices[0] = price;
        vm.prank(seller);
        m.list(address(nft), ids, prices, block.timestamp + 30 days);
    }

    function _buy(address who, MockNFT nft, uint256 id, uint256 maxPrice, uint256 value) internal {
        PentagonMarketplaceV3.BuyItem[] memory items = new PentagonMarketplaceV3.BuyItem[](1);
        items[0] = PentagonMarketplaceV3.BuyItem(address(nft), id, maxPrice);
        vm.prank(who);
        m.buy{value: value}(items);
    }

    function _ids(uint256 x) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = x;
    }

    function _leaf(uint256 id) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(id))));
    }

    function _hashPair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encode(x, y)) : keccak256(abi.encode(y, x));
    }

    // ───────── listings ─────────

    function test_buy_paysSellerFeeAndDefaultRoyaltyToFloorFund() public {
        _list(alice, a, 1, 1 ether);
        _buy(buyer, a, 1, 1 ether, 1.2 ether); // overpay 0.175, refunded

        assertEq(a.ownerOf(1), buyer);
        assertEq(alice.balance, 0.975 ether); // price − 2.5% royalty; seller pays no fee
        assertEq(treasury.balance, 0.025 ether); // 2.5% buyer fee
        assertEq(floorFund.balance, 0.025 ether); // unregistered collection → floor fund
        assertEq(buyer.balance, 100 ether - 1.025 ether);
        (address seller,,,,,) = m.listings(address(a), 1);
        assertEq(seller, address(0));
    }

    function test_buy_revertsWhenListingDearerThanBuyerSaw() public {
        _list(alice, a, 1, 1 ether);
        _list(alice, a, 1, 5 ether); // front-run re-price
        vm.expectRevert(PentagonMarketplaceV3.PriceAboveMax.selector);
        _buy(buyer, a, 1, 1 ether, 6 ether);
    }

    function test_buy_revertsWhenUnderpaid() public {
        _list(alice, a, 1, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.InsufficientPayment.selector);
        _buy(buyer, a, 1, 1 ether, 1 ether); // fee not included
    }

    function test_buyMany_oneTransaction() public {
        _list(alice, a, 1, 1 ether);
        _list(alice, a, 2, 2 ether);
        PentagonMarketplaceV3.BuyItem[] memory items = new PentagonMarketplaceV3.BuyItem[](2);
        items[0] = PentagonMarketplaceV3.BuyItem(address(a), 1, 1 ether);
        items[1] = PentagonMarketplaceV3.BuyItem(address(a), 2, 2 ether);
        vm.prank(buyer);
        m.buy{value: 3.075 ether}(items);
        assertEq(a.ownerOf(1), buyer);
        assertEq(a.ownerOf(2), buyer);
        assertEq(treasury.balance, 0.075 ether);
    }

    function test_zombieListing_isClearedAndCannotComeBack() public {
        _list(alice, a, 1, 1 ether);
        vm.prank(alice);
        a.transferFrom(alice, carol, 1); // sold / moved elsewhere
        assertFalse(m.isListingLive(address(a), 1));

        vm.prank(makeAddr("keeper"));
        m.clearStale(address(a), _ids(1));

        vm.prank(carol);
        a.transferFrom(carol, alice, 1); // comes back to alice
        vm.expectRevert(PentagonMarketplaceV3.NotListed.selector);
        _buy(buyer, a, 1, 1 ether, 2 ether);
    }

    function test_clearStale_skipsLiveListings() public {
        _list(alice, a, 1, 1 ether);
        m.clearStale(address(a), _ids(1));
        assertTrue(m.isListingLive(address(a), 1));
    }

    function test_clearStale_removesWhenApprovalRevoked() public {
        _list(alice, a, 1, 1 ether);
        vm.prank(alice);
        a.setApprovalForAll(address(m), false);
        m.clearStale(address(a), _ids(1));
        (address seller,,,,,) = m.listings(address(a), 1);
        assertEq(seller, address(0));
    }

    function test_incrementNonce_cancelsAllListings() public {
        _list(alice, a, 1, 1 ether);
        _list(alice, a, 2, 1 ether);
        vm.prank(alice);
        m.incrementNonce();
        assertFalse(m.isListingLive(address(a), 1));
        vm.expectRevert(PentagonMarketplaceV3.ListingNotLive.selector);
        _buy(buyer, a, 2, 1 ether, 2 ether);
        _list(alice, a, 2, 1 ether); // new listings work again
        _buy(buyer, a, 2, 1 ether, 2 ether);
        assertEq(a.ownerOf(2), buyer);
    }

    function test_listing_mustExpireWithin180Days() public {
        vm.prank(alice);
        vm.expectRevert(PentagonMarketplaceV3.BadExpiry.selector);
        m.list(address(a), _ids(1), _ids(1 ether), block.timestamp + 181 days);
        vm.prank(alice);
        vm.expectRevert(PentagonMarketplaceV3.BadExpiry.selector);
        m.list(address(a), _ids(1), _ids(1 ether), block.timestamp);
    }

    function test_expiredListing_cannotBeBought() public {
        _list(alice, a, 1, 1 ether);
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(PentagonMarketplaceV3.ListingNotLive.selector);
        _buy(buyer, a, 1, 1 ether, 2 ether);
    }

    function test_list_requiresOwnershipApprovalAndAllowedCollection() public {
        vm.prank(bob);
        vm.expectRevert(PentagonMarketplaceV3.NotTokenOwner.selector);
        m.list(address(a), _ids(1), _ids(1 ether), block.timestamp + 1 days);

        a.mint(carol, 9); // carol never approved the marketplace
        vm.prank(carol);
        vm.expectRevert(PentagonMarketplaceV3.NotApproved.selector);
        m.list(address(a), _ids(9), _ids(1 ether), block.timestamp + 1 days);

        MockNFT c = new MockNFT("C");
        c.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(PentagonMarketplaceV3.CollectionNotAllowed.selector);
        m.list(address(c), _ids(1), _ids(1 ether), block.timestamp + 1 days);
    }

    function test_delist_onlySeller() public {
        _list(alice, a, 1, 1 ether);
        vm.prank(bob);
        vm.expectRevert(PentagonMarketplaceV3.NotSeller.selector);
        m.delist(address(a), _ids(1));
        vm.prank(alice);
        m.delist(address(a), _ids(1));
        assertFalse(m.isListingLive(address(a), 1));
    }

    // ───────── fees & royalties ─────────

    function test_feeAndRoyalty_frozenIntoListing() public {
        _list(alice, a, 1, 1 ether);
        vm.startPrank(owner);
        m.setFee(500);
        m.setDefaultRoyalty(1000);
        vm.stopPrank();
        _buy(buyer, a, 1, 1 ether, 1.025 ether); // still 2.5% fee
        assertEq(treasury.balance, 0.025 ether);
        assertEq(floorFund.balance, 0.025 ether); // still 2.5% royalty

        _list(alice, a, 2, 1 ether); // new listing takes the new rates
        _buy(buyer, a, 2, 1 ether, 1.05 ether);
        assertEq(treasury.balance, 0.075 ether);
        assertEq(floorFund.balance, 0.125 ether);
    }

    function test_caps() public {
        vm.startPrank(owner);
        vm.expectRevert(PentagonMarketplaceV3.BpsTooHigh.selector);
        m.setFee(501);
        vm.expectRevert(PentagonMarketplaceV3.BpsTooHigh.selector);
        m.setDefaultRoyalty(1001);
        vm.expectRevert(PentagonMarketplaceV3.BpsTooHigh.selector);
        m.registerRoyalty(address(a), creator, 1001);
        vm.stopPrank();
        vm.expectRevert(PentagonMarketplaceV3.BpsTooHigh.selector);
        new PentagonMarketplaceV3(owner, treasury, floorFund, 501, 250);
    }

    function test_registeredCreator_getsRoyalty_andCollectionErc2981IsIgnored() public {
        vm.prank(owner);
        m.registerRoyalty(address(a), creator, 500);
        (address r, uint256 bps, bool registered) = m.royaltyFor(address(a));
        assertEq(r, creator);
        assertEq(bps, 500);
        assertTrue(registered);

        _list(alice, a, 1, 1 ether);
        _buy(buyer, a, 1, 1 ether, 1.025 ether);
        assertEq(creator.balance, 0.05 ether);
        assertEq(floorFund.balance, 0);
        assertEq(alice.balance, 0.95 ether);

        vm.prank(owner);
        m.registerRoyalty(address(a), address(0), 0); // unregister → back to floor fund at default
        (r, bps, registered) = m.royaltyFor(address(a));
        assertEq(r, floorFund);
        assertEq(bps, 250);
        assertFalse(registered);
    }

    function test_creatorSelfServe_setsOwnRoyalty() public {
        OwnedNFT c = new OwnedNFT(creator);
        vm.prank(owner);
        m.setCollectionAllowed(address(c), true);
        assertEq(m.collectionOwner(address(c)), creator);

        vm.prank(alice); // not the collection's owner()
        vm.expectRevert(PentagonMarketplaceV3.NotCollectionOwner.selector);
        m.registerRoyaltyAsCreator(address(c), alice, 500);

        vm.prank(creator);
        vm.expectRevert(PentagonMarketplaceV3.BpsTooHigh.selector);
        m.registerRoyaltyAsCreator(address(c), creator, 1001);

        vm.prank(creator);
        m.registerRoyaltyAsCreator(address(c), creator, 500);
        (address r, uint256 bps, bool registered) = m.royaltyFor(address(c));
        assertEq(r, creator);
        assertEq(bps, 500);
        assertTrue(registered);

        c.mint(alice, 1);
        vm.prank(alice);
        c.setApprovalForAll(address(m), true);
        _list(alice, MockNFT(address(c)), 1, 1 ether);
        _buy(buyer, MockNFT(address(c)), 1, 1 ether, 1.025 ether);
        assertEq(creator.balance, 0.05 ether);
    }

    function test_creatorSelfServe_ownerCanOverrideAndBlock() public {
        OwnedNFT c = new OwnedNFT(creator);
        vm.prank(creator);
        m.registerRoyaltyAsCreator(address(c), creator, 1000);

        vm.startPrank(owner);
        m.registerRoyalty(address(c), carol, 300); // our override wins
        m.setSelfServeBlocked(address(c), true);
        vm.stopPrank();
        (address r, uint256 bps,) = m.royaltyFor(address(c));
        assertEq(r, carol);
        assertEq(bps, 300);

        vm.prank(creator);
        vm.expectRevert(PentagonMarketplaceV3.SelfServeIsBlocked.selector);
        m.registerRoyaltyAsCreator(address(c), creator, 1000);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        m.setSelfServeBlocked(address(c), false);
    }

    function test_creatorSelfServe_impossibleWithoutOwnerFunction() public {
        // MockNFT has no owner(): nobody can self-register; only our owner can.
        assertEq(m.collectionOwner(address(a)), address(0));
        vm.prank(alice);
        vm.expectRevert(PentagonMarketplaceV3.NotCollectionOwner.selector);
        m.registerRoyaltyAsCreator(address(a), alice, 500);
    }

    function test_adminFunctions_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        m.setFee(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        m.registerRoyalty(address(a), alice, 1000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        m.setTreasury(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        m.setCollectionAllowed(address(a), false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        m.pause();
        vm.stopPrank();
    }

    function test_ownership_isTwoStep() public {
        vm.prank(owner);
        m.transferOwnership(alice);
        assertEq(m.owner(), owner);
        vm.prank(alice);
        m.acceptOwnership();
        assertEq(m.owner(), alice);
    }

    // ───────── offers ─────────

    function _offer(uint256 price, uint256 qty, bytes32 root) internal returns (uint256 id) {
        uint256 fee = (price * 250) / 10_000;
        vm.prank(buyer);
        id = m.placeOffer{value: (price + fee) * qty}(address(a), price, qty, block.timestamp + 7 days, root);
    }

    function test_offer_onlyItsOwnCollectionCanFillIt() public {
        uint256 id = _offer(1 ether, 1, bytes32(0));
        // bob holds B #1 but no A tokens: the live V2 bug let him fill an A offer with B #1.
        vm.prank(bob);
        vm.expectRevert();
        m.acceptOffer(id, _ids(1), new bytes32[][](0));
        assertEq(b.ownerOf(1), bob);
        assertEq(a.ownerOf(1), alice);
    }

    function test_offer_fill_paysSellerAndEscrowsRest() public {
        uint256 id = _offer(1 ether, 2, bytes32(0));
        assertEq(address(m).balance, 2.05 ether);

        vm.prank(alice);
        m.acceptOffer(id, _ids(3), new bytes32[][](0));
        assertEq(a.ownerOf(3), buyer);
        assertEq(alice.balance, 0.975 ether);
        assertEq(treasury.balance, 0.025 ether);
        assertEq(floorFund.balance, 0.025 ether);
        assertEq(address(m).balance, 1.025 ether); // one fill left

        uint256 before = buyer.balance;
        vm.prank(buyer);
        m.cancelOffer(id);
        assertEq(buyer.balance, before + 1.025 ether);
        assertEq(address(m).balance, 0);
    }

    function test_offer_cannotOverfill() public {
        uint256 id = _offer(1 ether, 1, bytes32(0));
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        vm.prank(alice);
        vm.expectRevert(PentagonMarketplaceV3.BadQuantity.selector);
        m.acceptOffer(id, ids, new bytes32[][](0));

        vm.prank(alice);
        m.acceptOffer(id, _ids(1), new bytes32[][](0));
        vm.prank(alice);
        vm.expectRevert(PentagonMarketplaceV3.OfferNotLive.selector);
        m.acceptOffer(id, _ids(2), new bytes32[][](0));
    }

    function test_offer_wrongPaymentReverts() public {
        vm.prank(buyer);
        vm.expectRevert(PentagonMarketplaceV3.WrongPayment.selector);
        m.placeOffer{value: 1 ether}(address(a), 1 ether, 1, block.timestamp + 1 days, bytes32(0));
    }

    function test_traitOffer_onlyTokensInTheSet() public {
        bytes32 root = _hashPair(_leaf(2), _leaf(3)); // e.g. "gold background" = tokens 2 and 3
        uint256 id = _offer(1 ether, 2, root);

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = _leaf(3);
        vm.prank(alice);
        m.acceptOffer(id, _ids(2), proofs);
        assertEq(a.ownerOf(2), buyer);

        proofs[0][0] = _leaf(2); // token 4 is not in the set, whatever proof is given
        vm.prank(alice);
        vm.expectRevert(PentagonMarketplaceV3.TokenNotInOffer.selector);
        m.acceptOffer(id, _ids(4), proofs);
    }

    function test_acceptOffer_removesTheTokensListing() public {
        _list(alice, a, 1, 5 ether);
        uint256 id = _offer(1 ether, 1, bytes32(0));
        vm.prank(alice);
        m.acceptOffer(id, _ids(1), new bytes32[][](0));
        (address seller,,,,,) = m.listings(address(a), 1);
        assertEq(seller, address(0));
    }

    function test_expiredOffer_cannotBeFilledButCanBeCancelled() public {
        uint256 id = _offer(1 ether, 1, bytes32(0));
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        vm.expectRevert(PentagonMarketplaceV3.OfferNotLive.selector);
        m.acceptOffer(id, _ids(1), new bytes32[][](0));
        vm.prank(buyer);
        m.cancelOffer(id);
        assertEq(buyer.balance, 100 ether);
    }

    function test_cancelOffer_onlyBidder() public {
        uint256 id = _offer(1 ether, 1, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(PentagonMarketplaceV3.NotBidder.selector);
        m.cancelOffer(id);
    }

    function test_refundOffers_ownerCanOnlyRefundToBidder() public {
        uint256 id = _offer(1 ether, 3, bytes32(0));
        uint256[] memory ids = _ids(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        m.refundOffers(ids);
        vm.prank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector); // never on a live book
        m.refundOffers(ids);

        vm.startPrank(owner);
        m.pause();
        m.refundOffers(ids);
        vm.stopPrank();
        assertEq(buyer.balance, 100 ether);
        assertEq(owner.balance, 0);
    }

    function test_selfTrade_blocked() public {
        _list(alice, a, 1, 1 ether);
        vm.deal(alice, 2 ether);
        vm.expectRevert(PentagonMarketplaceV3.SelfTrade.selector);
        _buy(alice, a, 1, 1 ether, 1.025 ether);

        a.mint(buyer, 50);
        vm.prank(buyer);
        a.setApprovalForAll(address(m), true);
        uint256 id = _offer(1 ether, 1, bytes32(0));
        vm.prank(buyer);
        vm.expectRevert(PentagonMarketplaceV3.SelfTrade.selector);
        m.acceptOffer(id, _ids(50), new bytes32[][](0));
    }

    function test_offer_royaltyFrozenWhenPlaced() public {
        uint256 id = _offer(1 ether, 1, bytes32(0));
        vm.prank(owner);
        m.registerRoyalty(address(a), creator, 1000); // registered after the offer was made
        vm.prank(alice);
        m.acceptOffer(id, _ids(1), new bytes32[][](0));
        assertEq(alice.balance, 0.975 ether); // still the 2.5% from when the offer was placed
        assertEq(creator.balance, 0.025 ether); // paid to the current receiver
    }

    // Root and proof made by the OpenZeppelin merkle-tree JS library (npm, v1.0.8):
    // StandardMerkleTree.of([[2],[3],[5],[11],[4096]], ["uint256"]), proof for 5.
    function test_traitOffer_acceptsProofFromTheJsLibrary() public {
        bytes32 root = 0x48e727200e32f97cee765fffd123e26b7f91632b78e44a153e94a3a6acdad0d1;
        uint256 id = _offer(1 ether, 1, root);
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](3);
        proofs[0][0] = 0x1ab0c6948a275349ae45a06aad66a8bd65ac18074615d53676c09b67809099e0;
        proofs[0][1] = 0xb2ac7d4e10f072d9f46be3db644ef1be450423557f8fa8d52ccc7cf0d7e8c319;
        proofs[0][2] = 0x597237c1d6e24e6a10ee1ffad0cc6b409d893b4096f12a57709bba26074862d6;
        vm.prank(alice);
        m.acceptOffer(id, _ids(5), proofs);
        assertEq(a.ownerOf(5), buyer);
    }

    // ───────── payouts & pause ─────────

    function test_rejectingSeller_isPaidLaterViaWithdraw() public {
        PickySeller s = new PickySeller();
        a.mint(address(s), 7);
        s.approve(a, address(m));
        s.list(m, address(a), 7, 1 ether);

        _buy(buyer, a, 7, 1 ether, 1.025 ether); // sale still goes through
        assertEq(a.ownerOf(7), buyer);
        assertEq(m.pendingPayouts(address(s)), 0.975 ether);

        s.setAccept(true);
        s.withdraw(m);
        assertEq(address(s).balance, 0.975 ether);
        assertEq(m.pendingPayouts(address(s)), 0);
    }

    function test_pause_stopsTradingButNotExits() public {
        _list(alice, a, 1, 1 ether);
        uint256 id = _offer(1 ether, 1, bytes32(0));
        vm.prank(owner);
        m.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        _buy(buyer, a, 1, 1 ether, 2 ether);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        m.acceptOffer(id, _ids(2), new bytes32[][](0));

        vm.prank(buyer);
        m.cancelOffer(id); // exits always work
        vm.prank(alice);
        m.delist(address(a), _ids(1));
        assertEq(buyer.balance, 100 ether);
    }

    function test_disallowedCollection_stopsSalesOfExistingListings() public {
        _list(alice, a, 1, 1 ether);
        vm.prank(owner);
        m.setCollectionAllowed(address(a), false);
        vm.expectRevert(PentagonMarketplaceV3.CollectionNotAllowed.selector);
        _buy(buyer, a, 1, 1 ether, 2 ether);
    }

    function test_plainTransfersRejected() public {
        vm.prank(buyer);
        (bool ok,) = address(m).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
