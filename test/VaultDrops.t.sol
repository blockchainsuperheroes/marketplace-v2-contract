// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PentagonVaultDrops} from "../src/VaultDrops.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

// Stand-in for a future fix/tuning release: same storage, one new view.
contract PentagonVaultDropsV2 is PentagonVaultDrops {
    function version() external pure returns (uint256) { return 2; }
}

contract VaultDropsTest is Test {
    PentagonVaultDrops vd;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    // prize ref: BCSH ETH #42 on Ethereum
    uint64 constant PRIZE_CHAIN = 1;
    address constant PRIZE_CONTRACT = 0x67abaDDb1258077F7900abD8AdE0EcC6CdC38ac2;

    // Mirrors production: a throwaway deployer creates impl + proxy, but ownership AND upgrade
    // rights go to the hardware wallet (`hw`) in the same transactions — the deployer keeps nothing.
    address hw = makeAddr("hw");
    address deployer = makeAddr("throwawayDeployer");
    ProxyAdmin admin;

    function setUp() public {
        vm.startPrank(deployer);
        PentagonVaultDrops impl = new PentagonVaultDrops();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), hw, abi.encodeCall(PentagonVaultDrops.initialize, (hw))
        );
        vm.stopPrank();
        vd = PentagonVaultDrops(payable(address(proxy)));
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT)))));
        // Tests drive owner-only calls from this contract: hw hands ownership over (two-step).
        vm.prank(hw);
        vd.transferOwnership(address(this));
        vd.acceptOwnership();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _create() internal returns (uint256 id) {
        id = vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 42, 1 ether, 1 days, 0, 0);
    }

    function _endTime(uint256 id) internal view returns (uint64 endTime) {
        (, , , , endTime, , , , , , , ) = vd.drops(id);
    }

    function testOnlyOwnerCreates() public {
        vm.prank(alice);
        vm.expectRevert();
        vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 42, 1 ether, 1 days, 0, 0);
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
        assertEq(vd.proceeds(), 0);
        assertEq(BURN.balance, 0);
    }

    function testFulfillRetainsProceedsNoBurn() public {
        uint256 id = _create();
        vm.prank(bob);
        vd.bid{value: 2 ether}(id);
        vm.warp(uint256(_endTime(id)) + 1);
        vd.settleDrop(id);
        vd.markFulfilled(id, bytes32(uint256(0xbeef)));
        assertEq(BURN.balance, 0, "nothing burned");
        assertEq(address(vd).balance, 2 ether, "stays in the contract");
        assertEq(vd.proceeds(), 2 ether, "owner-withdrawable");
        // owner may withdraw later, only up to proceeds
        vm.expectRevert(bytes("Bad amount"));
        vd.withdrawProceeds(treasury, 3 ether);
        vd.withdrawProceeds(treasury, 2 ether);
        assertEq(treasury.balance, 2 ether);
        assertEq(vd.proceeds(), 0);
    }

    function testProceedsNeverTouchOpenClaims() public {
        uint256 a = _createRedeemable();
        uint256 b = vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 99, 1 ether, 1 days, 0, 3 ether);
        vm.prank(bob);
        vd.redeem{value: 5 ether}(a);
        vm.prank(alice);
        vd.redeem{value: 3 ether}(b);
        vd.markFulfilled(a, bytes32(uint256(1)));
        // 8 PC in the contract, but only the delivered claim (5) is withdrawable
        assertEq(address(vd).balance, 8 ether);
        vm.expectRevert(bytes("Bad amount"));
        vd.withdrawProceeds(treasury, 6 ether);
        vd.withdrawProceeds(treasury, 5 ether);
        // alice's open claim is intact and reclaimable in full
        vm.warp(block.timestamp + 7 days);
        uint256 before = alice.balance;
        vm.prank(alice);
        vd.reclaimBid(b);
        assertEq(alice.balance, before + 3 ether);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        vd.withdrawProceeds(address(0xBEEF), 1);
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

    function testOwnerRefundAfterWrongFulfill() public {
        uint256 id = _create();
        vm.prank(bob);
        vd.bid{value: 2 ether}(id);
        vm.warp(uint256(_endTime(id)) + 1);
        vd.settleDrop(id);
        vd.markFulfilled(id, bytes32(uint256(1))); // mistaken mark — NFT never delivered
        uint256 before = bob.balance;
        vm.deal(address(this), 10 ether);
        vm.expectRevert(bytes("Must fund exact bid"));
        vd.ownerRefund{value: 1 ether}(id);
        vd.ownerRefund(id); // no value → paid from that claim's proceeds
        assertEq(bob.balance, before + 2 ether);
        assertEq(vd.proceeds(), 0);
        vm.expectRevert(bytes("Already reclaimed"));
        vd.ownerRefund(id);
        // not callable before a mark — reclaimBid is the normal path there
        uint256 id2 = _create();
        vm.expectRevert(bytes("Not fulfilled"));
        vd.ownerRefund{value: 0}(id2);
    }

    function testOwnerRefundFundedAfterProceedsWithdrawn() public {
        uint256 id = _createRedeemable();
        vm.prank(bob);
        vd.redeem{value: 5 ether}(id);
        vd.markFulfilled(id, bytes32(uint256(1)));
        vd.withdrawProceeds(treasury, 5 ether);
        vm.expectRevert(bytes("Insufficient proceeds"));
        vd.ownerRefund(id);
        vm.deal(address(this), 5 ether);
        uint256 before = bob.balance;
        vd.ownerRefund{value: 5 ether}(id);
        assertEq(bob.balance, before + 5 ether);
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
        vm.expectRevert(bytes("Bad window"));
        vd.setConfig(12 hours);
        vm.prank(alice);
        vm.expectRevert();
        vd.setConfig(7 days);
    }

    function _createRedeemable() internal returns (uint256 id) {
        id = vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 43, 1 ether, 1 days, 0, 5 ether);
    }

    function testClaimSettlesInstantly() public {
        uint256 id = _createRedeemable();
        vm.prank(bob);
        vd.redeem{value: 5 ether}(id);
        assertEq(address(vd).balance, 5 ether, "claim escrowed until delivery");
        (, , , , uint64 endTime, , , uint256 hb, address hbr, uint64 settledAt, , ) = vd.drops(id);
        assertEq(hbr, bob);
        assertEq(hb, 5 ether);
        assertTrue(settledAt != 0 && endTime == settledAt, "settled now");
        // normal escrow path continues: fulfill moves it to owner proceeds
        vd.markFulfilled(id, bytes32(uint256(9)));
        // no second redeem / bid after settle
        vm.prank(alice);
        vm.expectRevert(bytes("Settled"));
        vd.redeem{value: 5 ether}(id);
    }

    function testRedeemGuards() public {
        uint256 id = _createRedeemable();
        vm.prank(bob);
        vm.expectRevert(bytes("Pay exact redeem price"));
        vd.redeem{value: 4 ether}(id);
        // a Points-claim drop can never be bid on — at any amount
        vm.prank(bob);
        vm.expectRevert(bytes("Points claim only"));
        vd.bid{value: 1 ether}(id);
        vm.prank(bob);
        vm.expectRevert(bytes("Points claim only"));
        vd.bid{value: 9 ether}(id);
        // auction-only drop can't be redeemed
        uint256 id2 = _create();
        vm.prank(bob);
        vm.expectRevert(bytes("Not redeemable"));
        vd.redeem{value: 1 ether}(id2);
        // redeem below start price rejected at create
        vm.expectRevert(bytes("Redeem below start"));
        vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 44, 1 ether, 1 days, 0, 0.5 ether);
    }

    // Settlement-ledger events: payment.pentagon.games indexes Claimed / Delivered / Reclaimed.
    event Claimed(uint256 indexed dropId, address indexed claimer, uint256 amount, bytes32 ref);
    event Delivered(uint256 indexed dropId, uint256 amount);
    event Reclaimed(uint256 indexed dropId, address indexed claimer, uint256 amount);

    function testLedgerEventsClaimDeliver() public {
        uint256 id = _createRedeemable();
        vm.expectEmit(true, true, false, true);
        emit Claimed(id, bob, 5 ether, keccak256(abi.encode(id, bob)));
        vm.prank(bob);
        vd.redeem{value: 5 ether}(id);
        vm.expectEmit(true, false, false, true);
        emit Delivered(id, 5 ether);
        vd.markFulfilled(id, bytes32(uint256(7)));
    }

    function testLedgerEventsClaimReclaimExactAmountToClaimer() public {
        uint256 id = _createRedeemable();
        vm.prank(bob);
        vd.redeem{value: 5 ether}(id);
        vm.warp(block.timestamp + 7 days);
        uint256 before = bob.balance;
        vm.expectEmit(true, true, false, true);
        emit Reclaimed(id, bob, 5 ether);
        vm.prank(bob);
        vd.reclaimBid(id);
        assertEq(bob.balance, before + 5 ether, "exactly this claim, to this claimer");
        // someone else can never reclaim it
        vm.prank(alice);
        vm.expectRevert(bytes("Not winner"));
        vd.reclaimBid(id);
    }

    // ─── Proxy / upgrade rights ─────────────────────────────────
    function testDeployerKeepsNothing() public view {
        assertEq(admin.owner(), hw, "only hw can upgrade");
        assertTrue(vd.owner() != deployer && admin.owner() != deployer, "throwaway holds no authority");
        assertEq(vd.fulfillWindow(), 7 days, "initialized behind the proxy");
    }

    function testOnlyHwCanUpgradeAndStateSurvives() public {
        uint256 id = _createRedeemable();
        vm.prank(bob);
        vd.redeem{value: 5 ether}(id);
        PentagonVaultDropsV2 v2 = new PentagonVaultDropsV2();
        // anyone else — including the deployer and the contract owner — cannot upgrade
        vm.prank(deployer);
        vm.expectRevert();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(vd)), address(v2), "");
        vm.expectRevert();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(vd)), address(v2), "");
        // hw can
        vm.prank(hw);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(vd)), address(v2), "");
        assertEq(PentagonVaultDropsV2(payable(address(vd))).version(), 2);
        // claims + escrow survive the upgrade
        (, , , , , , , uint256 hb, address hbr, , , ) = vd.drops(id);
        assertEq(hbr, bob);
        assertEq(hb, 5 ether);
        assertEq(address(vd).balance, 5 ether);
    }

    function testImplementationCannotBeInitialized() public {
        PentagonVaultDrops impl = new PentagonVaultDrops();
        vm.expectRevert();
        impl.initialize(address(this));
    }

    function testProxyCannotBeReinitialized() public {
        vm.expectRevert();
        vd.initialize(alice);
    }

    // ─── reclaimFor: anyone can make the claimer whole after the window ──
    function testReclaimForByAnyonePaysClaimer() public {
        uint256 id = _createRedeemable();
        vm.prank(bob);
        vd.redeem{value: 5 ether}(id);
        vm.expectRevert(bytes("Fulfill window open"));
        vd.reclaimFor(id);
        vm.warp(block.timestamp + 7 days);
        uint256 before = bob.balance;
        vm.prank(alice); // a stranger (or our keeper) triggers it — bob sends nothing
        vd.reclaimFor(id);
        assertEq(bob.balance, before + 5 ether, "full amount to the claimer, never the caller");
        vm.expectRevert(bytes("Already reclaimed"));
        vd.reclaimFor(id);
        vm.prank(bob);
        vm.expectRevert(bytes("Already reclaimed"));
        vd.reclaimBid(id);
    }

    function testReclaimForBlockedAfterDelivery() public {
        uint256 id = _createRedeemable();
        vm.prank(bob);
        vd.redeem{value: 5 ether}(id);
        vd.markFulfilled(id, bytes32(uint256(3)));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(bytes("Fulfilled"));
        vd.reclaimFor(id);
    }

    // ─── open-ended Points listings (no expiry until claimed or delisted) ──
    function testOpenEndedClaimListingStaysUpUntilDelisted() public {
        uint256 id = vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 77, 2 ether, 0, 0, 2 ether);
        assertEq(_endTime(id), type(uint64).max);
        vm.warp(block.timestamp + 3650 days); // ten years later, still claimable
        vm.prank(bob);
        vd.redeem{value: 2 ether}(id);
        (, , , , , , , , address who, , , ) = vd.drops(id);
        assertEq(who, bob);
    }

    function testOpenEndedCanBeDelisted() public {
        uint256 id = vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 78, 2 ether, 0, 0, 2 ether);
        vd.cancelDrop(id);
        vm.prank(bob);
        vm.expectRevert(bytes("Settled"));
        vd.redeem{value: 2 ether}(id);
    }

    function testOpenEndedOnlyForClaims() public {
        vm.expectRevert(bytes("Bad duration"));
        vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 79, 1 ether, 0, 0, 0); // auction must have an end
    }

    // ─── v4: seller listings, 90/10 split, deliverTo, one live listing ──
    address seller = makeAddr("seller");
    address eoa = makeAddr("boundEOA");

    function testSellerListing_claimDeliver_pays90_10() public {
        vm.prank(seller);
        uint256 id = vd.listForPoints(PRIZE_CONTRACT, 500, 3, 10 ether);
        assertEq(vd.sellerOf(id), seller);
        assertEq(vd.lockIdOf(id), 3);
        vm.prank(bob);
        vd.redeem{value: 10 ether}(id, eoa);
        assertEq(vd.deliverToOf(id), eoa, "delivery address recorded on-chain");
        vd.markFulfilled(id, bytes32(uint256(5)));
        assertEq(vd.pendingReturns(seller), 9 ether, "seller credited 90%");
        assertEq(vd.proceeds(), 1 ether, "project keeps 10%");
        vm.prank(alice); // anyone can push it to the seller
        vd.withdrawPendingFor(seller);
        assertEq(seller.balance, 9 ether, "seller paid 90%");
    }

    function testSellerListing_reclaimPaysClaimerNotSeller() public {
        vm.prank(seller);
        uint256 id = vd.listForPoints(PRIZE_CONTRACT, 501, 4, 2 ether);
        vm.prank(bob);
        vd.redeem{value: 2 ether}(id, eoa);
        vm.warp(block.timestamp + 7 days);
        uint256 before = bob.balance;
        vd.reclaimFor(id);
        assertEq(bob.balance, before + 2 ether, "refund goes to the claimer, not deliverTo or seller");
        assertEq(seller.balance, 0);
    }

    function testSellerDelist_onlySeller_onlyUnclaimed() public {
        vm.prank(seller);
        uint256 id = vd.listForPoints(PRIZE_CONTRACT, 502, 5, 1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("Not seller"));
        vd.sellerDelist(id);
        vm.prank(seller);
        vd.sellerDelist(id);
        vm.prank(bob);
        vm.expectRevert(bytes("Settled"));
        vd.redeem{value: 1 ether}(id);
        vm.prank(seller);
        uint256 id2 = vd.listForPoints(PRIZE_CONTRACT, 502, 5, 1 ether); // relist after delist ok
        vm.prank(bob);
        vd.redeem{value: 1 ether}(id2);
        vm.prank(seller);
        vm.expectRevert(bytes("Invalid drop")); // claimed = settled: can't be delisted any more
        vd.sellerDelist(id2);
    }

    function testOneLiveListingPerLister_strangerCannotBlock() public {
        vm.prank(seller);
        vd.listForPoints(PRIZE_CONTRACT, 503, 6, 1 ether);
        vm.prank(seller);
        vm.expectRevert(bytes("Already listed"));
        vd.listForPoints(PRIZE_CONTRACT, 503, 6, 2 ether);
        vm.prank(alice); // a stranger's (fake) listing of the same token doesn't block anyone
        vd.listForPoints(PRIZE_CONTRACT, 503, 6, 1 ether);
        vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 503, 1 ether, 0, 0, 1 ether); // project can still list
        vm.expectRevert(bytes("Already listed"));
        vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 503, 1 ether, 0, 0, 1 ether); // but only once
    }

    function testRedeemDeliverToZeroReverts() public {
        uint256 id = vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 504, 1 ether, 0, 0, 1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("Bad deliverTo"));
        vd.redeem{value: 1 ether}(id, address(0));
        vm.prank(bob);
        vm.expectRevert(bytes("Bad deliverTo"));
        vd.redeem{value: 1 ether}(id, address(vd));
    }

    function testProjectListingStill100PercentProceeds() public {
        uint256 id = vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 505, 1 ether, 0, 0, 3 ether);
        vm.prank(bob);
        vd.redeem{value: 3 ether}(id);
        vd.markFulfilled(id, bytes32(uint256(6)));
        assertEq(vd.proceeds(), 3 ether);
    }

    // ─── review fixes ───────────────────────────────────────────
    function testCannotResellWhileClaimPending() public {
        vm.prank(seller);
        uint256 id = vd.listForPoints(PRIZE_CONTRACT, 600, 7, 1 ether);
        vm.prank(bob);
        vd.redeem{value: 1 ether}(id);
        vm.prank(seller);
        vm.expectRevert(bytes("Already listed")); // claimed, not yet delivered/refunded → still taken
        vd.listForPoints(PRIZE_CONTRACT, 600, 7, 1 ether);
        vd.refundUndelivered(id);
        vm.prank(seller);
        vd.listForPoints(PRIZE_CONTRACT, 600, 7, 1 ether); // freed once refunded
    }

    function testHostileSellerCannotBlockReceipt() public {
        HostileSeller h = new HostileSeller();
        vm.prank(address(h));
        uint256 id = vd.listForPoints(PRIZE_CONTRACT, 601, 8, 1 ether);
        vm.prank(bob);
        vd.redeem{value: 1 ether}(id);
        vd.markFulfilled(id, bytes32(uint256(9))); // must not revert even though the seller can't receive
        assertEq(vd.pendingReturns(address(h)), 0.9 ether);
        vm.expectRevert(bytes("Withdraw failed"));
        vd.withdrawPendingFor(address(h)); // only the hostile seller's own payout is affected
    }

    function testRefundUndelivered_ownerOnly_paysClaimer() public {
        uint256 id = _createRedeemable();
        vm.prank(bob);
        vd.redeem{value: 5 ether}(id);
        vm.prank(alice);
        vm.expectRevert(bytes("Not owner"));
        vd.refundUndelivered(id);
        uint256 before = bob.balance;
        vd.refundUndelivered(id);
        assertEq(bob.balance, before + 5 ether);
        vm.expectRevert(bytes("Already reclaimed"));
        vd.refundUndelivered(id);
    }

    // ─── price change in place ──────────────────────────────────
    function testUpdatePriceInPlace_projectAndSeller() public {
        uint256 id = vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 700, 1 ether, 0, 0, 1 ether);
        vd.updatePrice(id, 3 ether);
        assertEq(vd.dropCounter(), id, "no new listing created");
        vm.prank(bob);
        vm.expectRevert(bytes("Pay exact redeem price")); // a claim at the old price can't go through
        vd.redeem{value: 1 ether}(id);
        vm.prank(bob);
        vd.redeem{value: 3 ether}(id);
        vm.expectRevert(bytes("Not open")); // can't reprice once claimed
        vd.updatePrice(id, 5 ether);

        vm.prank(seller);
        uint256 sid = vd.listForPoints(PRIZE_CONTRACT, 701, 9, 2 ether);
        vm.expectRevert(bytes("Not lister")); // owner can't reprice a seller's listing
        vd.updatePrice(sid, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("Not lister"));
        vd.updatePrice(sid, 1 ether);
        vm.prank(seller);
        vd.updatePrice(sid, 4 ether);
    }

    // ── v5: receipt poster (the keeper posts delivery receipts after its own release confirms) ──
    function _claimed() internal returns (uint256 id) {
        id = vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 42, 1 ether, 0, 0, 1 ether);
        vm.prank(alice);
        vd.redeem{value: 1 ether}(id);
    }

    function testReceiptPoster_postsReceipt_strangerCannot() public {
        uint256 id = _claimed();
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        vm.expectRevert(bytes("Not owner"));
        vd.markFulfilled(id, bytes32(uint256(1))); // not set yet
        vd.setReceiptPoster(keeper);
        assertEq(vd.receiptPoster(), keeper);
        vm.prank(bob);
        vm.expectRevert(bytes("Not owner"));
        vd.markFulfilled(id, bytes32(uint256(1)));
        vm.prank(keeper);
        vd.markFulfilled(id, bytes32(uint256(1)));
        (, , , , , , , , , , bool fulfilled, ) = vd.drops(id);
        assertTrue(fulfilled);
        assertEq(vd.proceeds(), 1 ether);
        vm.prank(keeper);
        vm.expectRevert(bytes("Already fulfilled"));
        vd.markFulfilled(id, bytes32(uint256(2)));
    }

    function testReceiptPoster_ownerAlsoStillPosts() public {
        uint256 id = _claimed();
        vd.setReceiptPoster(makeAddr("keeper"));
        vd.markFulfilled(id, bytes32(uint256(1)));
        (, , , , , , , , , , bool fulfilled, ) = vd.drops(id);
        assertTrue(fulfilled);
    }

    function testReceiptPoster_onlyOwnerSets_andClearing_revokes() public {
        address keeper = makeAddr("keeper");
        vm.prank(alice);
        vm.expectRevert(bytes("Not owner"));
        vd.setReceiptPoster(alice);
        vd.setReceiptPoster(keeper);
        vd.setReceiptPoster(address(0));
        uint256 id = _claimed();
        vm.prank(keeper);
        vm.expectRevert(bytes("Not owner"));
        vd.markFulfilled(id, bytes32(uint256(1)));
        // address(0) can never be the poster
        vm.prank(address(0));
        vm.expectRevert(bytes("Not owner"));
        vd.markFulfilled(id, bytes32(uint256(1)));
    }

    function testReceiptPoster_hasNoOtherOwnerPowers() public {
        address keeper = makeAddr("keeper");
        vd.setReceiptPoster(keeper);
        uint256 id = _claimed();
        vm.startPrank(keeper);
        vm.expectRevert(bytes("Not owner"));
        vd.createDrop(PRIZE_CHAIN, PRIZE_CONTRACT, 43, 1 ether, 0, 0, 1 ether);
        vm.expectRevert(bytes("Not owner"));
        vd.refundUndelivered(id);
        vm.expectRevert(bytes("Not owner"));
        vd.withdrawProceeds(keeper, 1);
        vm.expectRevert(bytes("Not owner"));
        vd.setReceiptPoster(keeper);
        vm.stopPrank();
    }
}

contract HostileSeller {
    receive() external payable { revert("no"); }
}
