// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PentagonMarketplaceV3} from "../src/MarketplaceV3.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract SNFT is ERC721 {
    constructor() ERC721("S", "S") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

/// A smart-contract wallet (ERC-1271) whose signer is an EOA key.
contract Wallet1271 {
    address public signer;
    constructor(address s) { signer = s; }
    function approve(ERC721 nft, address op) external { nft.setApprovalForAll(op, true); }
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address r,,) = ECDSA.tryRecover(hash, sig);
        return r == signer && r != address(0) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
    receive() external payable {}
}

/// A seller wallet that tries to re-enter buySigned when it is paid.
contract ReenteringSeller {
    PentagonMarketplaceV3 public m;
    bytes public payload;
    bool public reentered;
    constructor(PentagonMarketplaceV3 m_) { m = m_; }
    function approve(ERC721 nft) external { nft.setApprovalForAll(address(m), true); }
    function arm(bytes calldata p) external { payload = p; }
    function pull() external { m.withdraw(); }
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) { return 0x1626ba7e; }
    receive() external payable {
        (bool ok,) = address(m).call{value: 1.025 ether}(payload);
        reentered = ok;
        require(ok, "reentry failed");
    }
}

contract MarketplaceV3SignedTest is Test {
    PentagonMarketplaceV3 m;
    SNFT a;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address buyer = makeAddr("buyer");
    address other = makeAddr("other");
    address creator = makeAddr("creator");
    address alice;
    uint256 aliceKey;
    address cs;
    uint256 csKey;
    address mallory;
    uint256 malloryKey;

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("alice");
        (cs, csKey) = makeAddrAndKey("cosigner");
        (mallory, malloryKey) = makeAddrAndKey("mallory");
        m = new PentagonMarketplaceV3(owner, treasury, 250, 250);
        a = new SNFT();
        vm.startPrank(owner);
        m.setCollectionAllowed(address(a), true);
        m.setCosigner(cs);
        vm.stopPrank();
        for (uint256 i = 1; i <= 5; ++i) a.mint(alice, i);
        vm.prank(alice);
        a.setApprovalForAll(address(m), true);
        vm.deal(buyer, 100 ether);
        vm.deal(other, 100 ether);
        vm.warp(1_000_000);
    }

    // ───────── helpers ─────────

    function _fixed(address seller, uint256 id, uint256 price) internal view returns (PentagonMarketplaceV3.Order memory o) {
        o.seller = seller;
        o.collection = address(a);
        o.tokenId = id;
        o.startPrice = uint96(price);
        o.endPrice = uint96(price);
        o.priceMin = uint96(price);
        o.priceMax = uint96(price);
        o.feeBps = 250;
        o.royaltyBps = 250;
        o.nonce = m.sellerNonce(seller);
        o.start = uint40(block.timestamp);
        o.expiry = uint40(block.timestamp + 30 days);
        o.salt = 1;
    }

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _item(PentagonMarketplaceV3.Order memory o, uint256 sellerKey, address who, uint128 floor, uint256 maxPrice)
        internal
        view
        returns (PentagonMarketplaceV3.SignedBuy memory it)
    {
        bytes32 h = m.hashOrder(o);
        uint40 dl = uint40(block.timestamp + 5 minutes);
        it = PentagonMarketplaceV3.SignedBuy(
            o, _sig(sellerKey, h), floor, dl, _sig(csKey, m.fillAuthDigest(h, who, floor, dl)), maxPrice
        );
    }

    function _one(PentagonMarketplaceV3.SignedBuy memory it) internal pure returns (PentagonMarketplaceV3.SignedBuy[] memory r) {
        r = new PentagonMarketplaceV3.SignedBuy[](1);
        r[0] = it;
    }

    function _fill(PentagonMarketplaceV3.SignedBuy memory it, address who, uint256 value) internal {
        vm.prank(who);
        m.buySigned{value: value}(_one(it), 0);
    }

    function _price(PentagonMarketplaceV3.Order memory o, uint256 floor, uint256 t) internal view returns (uint256) {
        return m.priceAt(o, floor, t);
    }

    // ───────── happy path, fee and royalty ─────────

    function test_fixed_paysSellerFeeAndRoyalty() public {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        _fill(_item(o, aliceKey, buyer, 0, 1 ether), buyer, 1.2 ether);
        assertEq(a.ownerOf(1), buyer);
        assertEq(alice.balance, 0.975 ether);
        assertEq(m.floorFundOf(address(a)), 0.025 ether);
        assertEq(m.royaltyFundOf(address(a)), 0.025 ether);
        assertEq(buyer.balance, 100 ether - 1.025 ether);
        assertEq(treasury.balance, 0);
        assertEq(m.orderStatus(m.hashOrder(o)), 1);
        assertEq(address(m).balance, 0.05 ether); // exactly the two funds
    }

    function test_registeredRoyalty_paidToReceiver() public {
        vm.prank(owner);
        m.registerRoyalty(address(a), creator, 100);
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        _fill(_item(o, aliceKey, buyer, 0, 1 ether), buyer, 1.025 ether);
        assertEq(creator.balance, 0.01 ether); // today's 1%, below the 2.5% signed
        assertEq(alice.balance, 0.99 ether);
    }

    function test_royaltyRaisedAboveSigned_refused() public {
        vm.prank(owner);
        m.registerRoyalty(address(a), creator, 500);
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.RateAboveSigned.selector);
        _fill(it, buyer, 2 ether);
    }

    function test_feeRaisedAboveSigned_refused_feeLowered_chargesToday() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.prank(owner);
        m.setFee(300);
        vm.expectRevert(PentagonMarketplaceV3.RateAboveSigned.selector);
        _fill(it, buyer, 2 ether);
        vm.prank(owner);
        m.setFee(100);
        _fill(it, buyer, 2 ether);
        assertEq(m.floorFundOf(address(a)), 0.01 ether);
        assertEq(buyer.balance, 100 ether - 1.01 ether);
    }

    function test_sellerSignsZeroRates_refused() public {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.feeBps = 0;
        PentagonMarketplaceV3.SignedBuy memory pre1 = _item(o, aliceKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.RateAboveSigned.selector);
        _fill(pre1, buyer, 2 ether);
        o.feeBps = 250;
        o.royaltyBps = 0;
        PentagonMarketplaceV3.SignedBuy memory pre2 = _item(o, aliceKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.RateAboveSigned.selector);
        _fill(pre2, buyer, 2 ether);
    }

    function test_tipAndRefund() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.prank(buyer);
        m.buySigned{value: 2 ether}(_one(it), 0.05 ether);
        assertEq(treasury.balance, 0.05 ether);
        assertEq(buyer.balance, 100 ether - 1.075 ether);
    }

    function test_tipTooHigh() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(PentagonMarketplaceV3.TipTooHigh.selector);
        m.buySigned{value: 2 ether}(_one(it), 0.06 ether);
    }

    function test_underpaid() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.InsufficientPayment.selector);
        _fill(it, buyer, 1 ether);
    }

    function test_priceAboveBuyerMax() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 0.9 ether);
        vm.expectRevert(PentagonMarketplaceV3.PriceAboveMax.selector);
        _fill(it, buyer, 2 ether);
    }

    function test_batch_twoOrders() public {
        PentagonMarketplaceV3.SignedBuy[] memory items = new PentagonMarketplaceV3.SignedBuy[](2);
        items[0] = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        items[1] = _item(_fixed(alice, 2, 2 ether), aliceKey, buyer, 0, 2 ether);
        vm.prank(buyer);
        m.buySigned{value: 3.075 ether}(items, 0);
        assertEq(a.ownerOf(1), buyer);
        assertEq(a.ownerOf(2), buyer);
    }

    function test_fill_removesOnChainListingOfSameToken() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        ids[0] = 1;
        prices[0] = 5 ether;
        vm.prank(alice);
        m.list(address(a), ids, prices, block.timestamp + 1 days);
        _fill(_item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether), buyer, 1.025 ether);
        (address seller,,,,,) = m.listings(address(a), 1);
        assertEq(seller, address(0));
    }

    // ───────── co-signer ─────────

    function test_cosignerNotSet() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.prank(owner);
        m.setCosigner(address(0));
        vm.expectRevert(PentagonMarketplaceV3.CosignerNotSet.selector);
        _fill(it, buyer, 2 ether);
    }

    function test_cosignerMissingOrWrong() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        bytes memory good = it.cosignerSig;
        it.cosignerSig = "";
        vm.expectRevert(PentagonMarketplaceV3.BadCosignerSig.selector);
        _fill(it, buyer, 2 ether);
        it.cosignerSig = _sig(malloryKey, m.fillAuthDigest(m.hashOrder(it.order), buyer, 0, it.authDeadline));
        vm.expectRevert(PentagonMarketplaceV3.BadCosignerSig.selector);
        _fill(it, buyer, 2 ether);
        it.cosignerSig = good;
        _fill(it, buyer, 2 ether);
    }

    function test_cosignerAuth_isForOneBuyer() public {
        // The co-signer authorised `buyer` (in the audience); `other` can't use that authorisation.
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.BadCosignerSig.selector);
        _fill(it, other, 2 ether);
    }

    function test_cosignerAuth_bindsFloor() public {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.floorRef = 1 ether;
        o.upBps = 10_000;
        o.priceMax = 10 ether;
        PentagonMarketplaceV3.SignedBuy memory it = _item(o, aliceKey, buyer, 1 ether, 10 ether);
        it.floor = 2 ether; // buyer can't swap in a floor the co-signer didn't sign
        vm.expectRevert(PentagonMarketplaceV3.BadCosignerSig.selector);
        _fill(it, buyer, 20 ether);
    }

    function test_authExpiredOrTooLong() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.warp(block.timestamp + 5 minutes + 1);
        vm.expectRevert(PentagonMarketplaceV3.AuthExpired.selector);
        _fill(it, buyer, 2 ether);

        bytes32 h = m.hashOrder(it.order);
        uint40 dl = uint40(vm.getBlockTimestamp() + 5 minutes + 1); // via-ir caches block.timestamp across warp
        it.authDeadline = dl;
        it.cosignerSig = _sig(csKey, m.fillAuthDigest(h, buyer, 0, dl));
        vm.expectRevert(PentagonMarketplaceV3.AuthExpired.selector);
        _fill(it, buyer, 2 ether);
    }

    function test_setCosigner_onlyOwner() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        m.setCosigner(other);
    }

    // ───────── audience ─────────

    function _collectorsOnly() internal view returns (PentagonMarketplaceV3.Order memory o) {
        o = _fixed(alice, 1, 1 ether);
        o.audience = keccak256("collectors-only");
    }

    function test_audienceIsBoundIntoTheOrder() public {
        // (Fresh structs each time: memory structs alias when assigned.)
        PentagonMarketplaceV3.SignedBuy memory it = _item(_collectorsOnly(), aliceKey, buyer, 0, 1 ether);
        // Widening the audience to everyone after signing breaks the seller's signature.
        it.order.audience = bytes32(0);
        vm.expectRevert(PentagonMarketplaceV3.BadSellerSig.selector);
        _fill(it, buyer, 2 ether);

        // A co-signature for the collectors-only order can't be moved onto an everyone order either.
        PentagonMarketplaceV3.SignedBuy memory it2 = _item(_collectorsOnly(), aliceKey, buyer, 0, 1 ether);
        PentagonMarketplaceV3.Order memory open = _fixed(alice, 1, 1 ether);
        it2.order = open;
        it2.sellerSig = _sig(aliceKey, m.hashOrder(open));
        vm.expectRevert(PentagonMarketplaceV3.BadCosignerSig.selector);
        _fill(it2, buyer, 2 ether);

        // The real pair works.
        _fill(_item(_collectorsOnly(), aliceKey, buyer, 0, 1 ether), buyer, 2 ether);
        assertEq(a.ownerOf(1), buyer);
    }

    // ───────── seller signature and order state ─────────

    function test_badSellerSig() public {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        PentagonMarketplaceV3.SignedBuy memory pre3 = _item(o, malloryKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.BadSellerSig.selector);
        _fill(pre3, buyer, 2 ether);
    }

    function test_tamperedPrice_badSellerSig() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        it.order.priceMin = 0.1 ether;
        it.order.startPrice = 0.1 ether;
        it.order.endPrice = 0.1 ether;
        it.order.priceMax = 0.1 ether;
        vm.expectRevert(PentagonMarketplaceV3.BadSellerSig.selector);
        _fill(it, buyer, 2 ether);
    }

    function test_replay_refusedEvenIfNftComesBack() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        _fill(it, buyer, 1.025 ether);
        vm.prank(buyer);
        a.transferFrom(buyer, alice, 1);
        PentagonMarketplaceV3.SignedBuy memory again = _item(it.order, aliceKey, other, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.OrderNotLive.selector);
        _fill(again, other, 2 ether);
    }

    function test_cancelOrders() public {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        PentagonMarketplaceV3.Order[] memory os = new PentagonMarketplaceV3.Order[](1);
        os[0] = o;
        vm.prank(other);
        vm.expectRevert(PentagonMarketplaceV3.NotSeller.selector);
        m.cancelOrders(os);
        vm.prank(alice);
        m.cancelOrders(os);
        assertEq(m.orderStatus(m.hashOrder(o)), 2);
        PentagonMarketplaceV3.SignedBuy memory pre4 = _item(o, aliceKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.OrderNotLive.selector);
        _fill(pre4, buyer, 2 ether);
    }

    function test_cancelFilledOrder_reverts() public {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        _fill(_item(o, aliceKey, buyer, 0, 1 ether), buyer, 1.025 ether);
        PentagonMarketplaceV3.Order[] memory os = new PentagonMarketplaceV3.Order[](1);
        os[0] = o;
        vm.prank(alice);
        vm.expectRevert(PentagonMarketplaceV3.OrderNotLive.selector);
        m.cancelOrders(os);
    }

    function test_incrementNonce_cancelsAllSigned() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.prank(alice);
        m.incrementNonce();
        vm.expectRevert(PentagonMarketplaceV3.OrderNotLive.selector);
        _fill(it, buyer, 2 ether);
    }

    function test_notStarted_expired_tooLong() public {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.start = uint40(block.timestamp + 1);
        PentagonMarketplaceV3.SignedBuy memory pre5 = _item(o, aliceKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.OrderNotLive.selector);
        _fill(pre5, buyer, 2 ether);

        o = _fixed(alice, 1, 1 ether);
        o.expiry = uint40(block.timestamp - 1);
        o.start = uint40(block.timestamp - 2);
        PentagonMarketplaceV3.SignedBuy memory pre6 = _item(o, aliceKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.OrderNotLive.selector);
        _fill(pre6, buyer, 2 ether);

        o = _fixed(alice, 1, 1 ether);
        o.expiry = uint40(block.timestamp + 180 days + 1);
        PentagonMarketplaceV3.SignedBuy memory pre7 = _item(o, aliceKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.OrderNotLive.selector);
        _fill(pre7, buyer, 2 ether);
    }

    function test_sellerMovedNft_reverts() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.prank(alice);
        a.transferFrom(alice, other, 1);
        vm.expectRevert(); // the ERC-721 refuses: alice no longer owns it
        _fill(it, buyer, 2 ether);
    }

    function test_sellerRevokedApproval_reverts() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.prank(alice);
        a.setApprovalForAll(address(m), false);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(m), 1));
        _fill(it, buyer, 2 ether);
    }

    function test_selfTrade() public {
        vm.deal(alice, 10 ether);
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, alice, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.SelfTrade.selector);
        _fill(it, alice, 2 ether);
    }

    function test_paused_and_disallowed() public {
        PentagonMarketplaceV3.SignedBuy memory it = _item(_fixed(alice, 1, 1 ether), aliceKey, buyer, 0, 1 ether);
        vm.prank(owner);
        m.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _fill(it, buyer, 2 ether);
        vm.startPrank(owner);
        m.unpause();
        m.setCollectionAllowed(address(a), false);
        vm.stopPrank();
        vm.expectRevert(PentagonMarketplaceV3.CollectionNotAllowed.selector);
        _fill(it, buyer, 2 ether);
    }

    function test_cancelWorksWhilePaused() public {
        PentagonMarketplaceV3.Order[] memory os = new PentagonMarketplaceV3.Order[](1);
        os[0] = _fixed(alice, 1, 1 ether);
        vm.prank(owner);
        m.pause();
        vm.prank(alice);
        m.cancelOrders(os);
        assertEq(m.orderStatus(m.hashOrder(os[0])), 2);
    }

    // ───────── ERC-1271 seller ─────────

    function test_contractWalletSeller() public {
        Wallet1271 w = new Wallet1271(alice);
        a.mint(address(w), 9);
        w.approve(ERC721(address(a)), address(m));
        PentagonMarketplaceV3.Order memory o = _fixed(address(w), 9, 1 ether);
        _fill(_item(o, aliceKey, buyer, 0, 1 ether), buyer, 1.025 ether);
        assertEq(a.ownerOf(9), buyer);
        assertEq(address(w).balance, 0.975 ether);
    }

    function test_contractWalletSeller_wrongSigner() public {
        Wallet1271 w = new Wallet1271(alice);
        a.mint(address(w), 9);
        w.approve(ERC721(address(a)), address(m));
        PentagonMarketplaceV3.Order memory o = _fixed(address(w), 9, 1 ether);
        PentagonMarketplaceV3.SignedBuy memory pre8 = _item(o, malloryKey, buyer, 0, 1 ether);
        vm.expectRevert(PentagonMarketplaceV3.BadSellerSig.selector);
        _fill(pre8, buyer, 2 ether);
    }

    // ───────── reentrancy ─────────

    function test_reentrantSeller_cannotReenter_payoutDeferred() public {
        ReenteringSeller rs = new ReenteringSeller(m);
        vm.deal(address(rs), 2 ether);
        a.mint(address(rs), 7);
        rs.approve(ERC721(address(a)));
        PentagonMarketplaceV3.Order memory o1 = _fixed(address(rs), 7, 1 ether);
        PentagonMarketplaceV3.Order memory o2 = _fixed(alice, 2, 1 ether);
        // On payment, the seller tries to buy alice's order through buySigned, mid-sale.
        rs.arm(abi.encodeCall(m.buySigned, (_one(_item(o2, aliceKey, address(rs), 0, 1 ether)), 0)));
        _fill(_item(o1, aliceKey, buyer, 0, 1 ether), buyer, 1.025 ether);
        assertEq(a.ownerOf(7), buyer);
        assertFalse(rs.reentered());
        assertEq(m.pendingPayouts(address(rs)), 0.975 ether);
        assertEq(m.orderStatus(m.hashOrder(o2)), 0);
        assertEq(a.ownerOf(2), alice);
        // The same call made directly, not re-entering, works: the order itself was fine.
        bytes memory p = rs.payload();
        vm.prank(address(rs));
        (bool ok,) = address(m).call{value: 1.025 ether}(p);
        assertTrue(ok);
        assertEq(a.ownerOf(2), address(rs));
    }

    function test_reentrancyGuard_blocksBuySignedFromWithdraw() public {
        // withdraw() forwards all gas, so here the re-entry reaches the guard rather than running out of gas.
        ReenteringSeller rs = new ReenteringSeller(m);
        vm.deal(address(rs), 2 ether);
        a.mint(address(rs), 7);
        rs.approve(ERC721(address(a)));
        rs.arm(abi.encodeCall(m.buySigned, (_one(_item(_fixed(alice, 2, 1 ether), aliceKey, address(rs), 0, 1 ether)), 0)));
        _fill(_item(_fixed(address(rs), 7, 1 ether), aliceKey, buyer, 0, 1 ether), buyer, 1.025 ether);
        assertEq(m.pendingPayouts(address(rs)), 0.975 ether);
        vm.expectRevert(PentagonMarketplaceV3.WithdrawFailed.selector);
        rs.pull();
        assertEq(a.ownerOf(2), alice);
        assertEq(m.pendingPayouts(address(rs)), 0.975 ether);
    }

    // ───────── price rule ─────────

    function test_price_scheduleUp() public view {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.endPrice = 2 ether;
        o.priceMax = 2 ether;
        o.rampStart = uint40(block.timestamp + 30 days);
        o.rampEnd = uint40(block.timestamp + 60 days);
        assertEq(_price(o, 0, block.timestamp), 1 ether); // hold
        assertEq(_price(o, 0, o.rampStart), 1 ether);
        assertEq(_price(o, 0, block.timestamp + 45 days), 1.5 ether); // halfway
        assertEq(_price(o, 0, o.rampEnd), 2 ether);
        assertEq(_price(o, 0, block.timestamp + 90 days), 2 ether); // held after
    }

    function test_price_scheduleDown_dutch() public view {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 2 ether);
        o.endPrice = 1 ether;
        o.priceMin = 1 ether;
        o.rampStart = uint40(block.timestamp);
        o.rampEnd = uint40(block.timestamp + 10 days);
        assertEq(_price(o, 0, block.timestamp + 2 days), 1.8 ether);
        assertEq(_price(o, 0, block.timestamp + 10 days), 1 ether);
    }

    function test_price_stepWhenRampStartEqualsEnd() public view {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.endPrice = 3 ether;
        o.priceMax = 3 ether;
        o.rampStart = uint40(block.timestamp + 1 days);
        o.rampEnd = o.rampStart;
        assertEq(_price(o, 0, o.rampStart), 1 ether);
        assertEq(_price(o, 0, o.rampStart + 1), 3 ether);
    }

    function test_price_floorUp() public view {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.floorRef = 1 ether;
        o.upBps = 5000;
        o.downBps = 5000;
        o.priceMin = 0.1 ether;
        o.priceMax = 10 ether;
        assertEq(_price(o, 2 ether, block.timestamp), 1.5 ether); // r = 2 → 1 + 0.5 × 1
        assertEq(_price(o, 1 ether, block.timestamp), 1 ether); // r = 1
    }

    function test_price_floorDown() public view {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.floorRef = 1 ether;
        o.upBps = 10_000;
        o.downBps = 5000;
        o.priceMin = 0.1 ether;
        o.priceMax = 10 ether;
        assertEq(_price(o, 0.5 ether, block.timestamp), 0.75 ether); // r = 0.5 → 1 − 0.5 × 0.5
        assertEq(_price(o, 0, block.timestamp), 0.5 ether); // r = 0 → 1 − 0.5
    }

    function test_price_upOnly_neverCheaper() public view {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.floorRef = 1 ether;
        o.upBps = 10_000;
        o.priceMax = 10 ether;
        assertEq(_price(o, 0.2 ether, block.timestamp), 1 ether);
        assertEq(_price(o, 3 ether, block.timestamp), 3 ether);
    }

    function test_price_clamps() public view {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.floorRef = 1 ether;
        o.upBps = 10_000;
        o.downBps = 10_000;
        o.priceMin = 0.8 ether;
        o.priceMax = 1.5 ether;
        assertEq(_price(o, 0.1 ether, block.timestamp), 0.8 ether); // clamped up to min
        assertEq(_price(o, 5 ether, block.timestamp), 1.5 ether); // clamped down to max
    }

    function test_price_floorIgnoredWhenNoRef() public view {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        assertEq(_price(o, 100 ether, block.timestamp), 1 ether);
    }

    function test_price_badRules() public {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.priceMin = 0;
        vm.expectRevert(PentagonMarketplaceV3.BadPriceRule.selector);
        m.priceAt(o, 0, block.timestamp);
        o = _fixed(alice, 1, 1 ether);
        o.priceMin = 2 ether;
        vm.expectRevert(PentagonMarketplaceV3.BadPriceRule.selector);
        m.priceAt(o, 0, block.timestamp);
        o = _fixed(alice, 1, 1 ether);
        o.rampStart = 10;
        o.rampEnd = 5;
        vm.expectRevert(PentagonMarketplaceV3.BadPriceRule.selector);
        m.priceAt(o, 0, block.timestamp);
        o = _fixed(alice, 1, 1 ether);
        o.floorRef = 1 ether;
        o.upBps = 10_001;
        vm.expectRevert(PentagonMarketplaceV3.BadPriceRule.selector);
        m.priceAt(o, 0, block.timestamp);
        o = _fixed(alice, 1, 1 ether);
        o.upBps = 1; // floor sensitivity with no reference floor
        vm.expectRevert(PentagonMarketplaceV3.BadPriceRule.selector);
        m.priceAt(o, 0, block.timestamp);
    }

    function test_ruleFill_followsFloorAtSale() public {
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1 ether);
        o.floorRef = 1 ether;
        o.upBps = 10_000;
        o.downBps = 5000;
        o.priceMin = 0.5 ether;
        o.priceMax = 5 ether;
        _fill(_item(o, aliceKey, buyer, 1.2 ether, 1.2 ether), buyer, 1.23 ether);
        assertEq(alice.balance, 1.17 ether); // 1.2 − 2.5%
        assertEq(m.floorFundOf(address(a)), 0.03 ether);
    }

    function testFuzz_priceAlwaysWithinMinMax(
        uint96 p0,
        uint96 p1,
        uint128 f0,
        uint128 f,
        uint16 up,
        uint16 down,
        uint96 lo,
        uint96 hi,
        uint32 dt
    ) public view {
        lo = uint96(bound(lo, 1, type(uint96).max));
        hi = uint96(bound(hi, lo, type(uint96).max));
        f0 = uint128(bound(f0, 1, type(uint128).max));
        PentagonMarketplaceV3.Order memory o = _fixed(alice, 1, 1);
        o.startPrice = p0;
        o.endPrice = p1;
        o.rampStart = uint40(block.timestamp);
        o.rampEnd = uint40(block.timestamp + 30 days);
        o.floorRef = f0;
        o.upBps = uint16(bound(up, 0, 10_000));
        o.downBps = uint16(bound(down, 0, 10_000));
        o.priceMin = lo;
        o.priceMax = hi;
        uint256 p = _price(o, f, block.timestamp + dt);
        assertGe(p, lo);
        assertLe(p, hi);
    }
}
