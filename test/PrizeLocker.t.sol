// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PentagonPrizeLocker} from "../src/PrizeLocker.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockAzuki is ERC721 {
    constructor() ERC721("Azuki", "AZUKI") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract PrizeLockerTest is Test {
    PentagonPrizeLocker locker;
    MockAzuki nft;

    uint256 constant ADMIN_PK = 0xA0A0;
    uint256 constant OTHER_PK = 0xBAD;
    address admin = vm.addr(ADMIN_PK);
    address keeper = makeAddr("keeper");
    address depositor = makeAddr("depositor"); // nftprof's wallet in production
    address winner = makeAddr("winner");
    address thief = makeAddr("thief");

    uint256 constant T1 = 2678;
    uint256 constant T2 = 3071;

    function setUp() public {
        nft = new MockAzuki();
        locker = new PentagonPrizeLocker(admin, keeper, depositor);
        nft.mint(depositor, T1);
        nft.mint(depositor, T2);
        vm.startPrank(depositor);
        nft.setApprovalForAll(address(locker), true);
        locker.checkIn(address(nft), T1); // lock 1
        locker.checkIn(address(nft), T2); // lock 2
        vm.stopPrank();
    }

    function _sign(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _releaseSig(uint256 lockId, address to, uint256 dl) internal view returns (bytes memory) {
        return _sign(ADMIN_PK, locker.releaseDigest(lockId, to, dl));
    }

    function _withdrawSig(uint256 lockId, uint256 dl) internal view returns (bytes memory) {
        return _sign(ADMIN_PK, locker.withdrawDigest(lockId, dl));
    }

    // ─── check-in ───────────────────────────────────────────────
    function test_checkIn_locksAndIsVerifiable() public view {
        assertEq(nft.ownerOf(T1), address(locker));
        assertEq(locker.lockOf(address(nft), T1), 1);
        (address c, uint256 id, PentagonPrizeLocker.Status st) = locker.locks(1);
        assertEq(c, address(nft));
        assertEq(id, T1);
        assertEq(uint8(st), uint8(PentagonPrizeLocker.Status.Locked));
    }

    function test_checkIn_onlyDepositor() public {
        nft.mint(thief, 9);
        vm.startPrank(thief);
        nft.setApprovalForAll(address(locker), true);
        vm.expectRevert(PentagonPrizeLocker.NotDepositor.selector);
        locker.checkIn(address(nft), 9);
        vm.stopPrank();
    }

    function test_directTransferRejected() public {
        nft.mint(depositor, 77);
        vm.prank(depositor);
        vm.expectRevert(PentagonPrizeLocker.DirectTransferRejected.selector);
        nft.safeTransferFrom(depositor, address(locker), 77);
    }

    // ─── release ────────────────────────────────────────────────
    function test_release_keeperWithAdminSig() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _releaseSig(1, winner, dl);
        vm.prank(keeper);
        locker.release(1, winner, dl, sig);
        assertEq(nft.ownerOf(T1), winner);
        assertEq(locker.lockOf(address(nft), T1), 0);
    }

    function test_release_needsKeeper_evenWithValidSig() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _releaseSig(1, winner, dl);
        for (uint256 i; i < 3; i++) {
            address who = i == 0 ? depositor : i == 1 ? admin : thief;
            vm.prank(who);
            vm.expectRevert(PentagonPrizeLocker.NotKeeper.selector);
            locker.release(1, winner, dl, sig);
        }
    }

    function test_release_keeperAloneFails() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory keeperSelfSig = _sign(OTHER_PK, locker.releaseDigest(1, winner, dl));
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.release(1, winner, dl, keeperSelfSig);
    }

    function test_release_sigBoundToRecipient() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _releaseSig(1, winner, dl);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.release(1, thief, dl, sig);
    }

    function test_release_sigBoundToLock() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sigForLock1 = _releaseSig(1, winner, dl);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.release(2, winner, dl, sigForLock1);
        assertEq(nft.ownerOf(T2), address(locker));
    }

    function test_release_onceOnly() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _releaseSig(1, winner, dl);
        vm.prank(keeper);
        locker.release(1, winner, dl, sig);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLocker.NotLocked.selector);
        locker.release(1, winner, dl, sig);
    }

    function test_release_badRecipient() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory s0 = _releaseSig(1, address(0), dl);
        bytes memory sSelf = _releaseSig(1, address(locker), dl);
        vm.startPrank(keeper);
        vm.expectRevert(PentagonPrizeLocker.BadRecipient.selector);
        locker.release(1, address(0), dl, s0);
        vm.expectRevert(PentagonPrizeLocker.BadRecipient.selector);
        locker.release(1, address(locker), dl, sSelf);
        vm.stopPrank();
    }

    function test_deadline_expiredAndTooFar() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _releaseSig(1, winner, dl);
        vm.warp(dl + 1);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLocker.Expired.selector);
        locker.release(1, winner, dl, sig);
        uint256 far = block.timestamp + 48 hours + 1;
        bytes memory farSig = _releaseSig(1, winner, far);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLocker.DeadlineTooFar.selector);
        locker.release(1, winner, far, farSig);
    }

    function test_malformedSigReverts() public {
        vm.prank(keeper);
        vm.expectRevert();
        locker.release(1, winner, block.timestamp + 1 hours, hex"deadbeef");
    }

    // ─── withdraw ───────────────────────────────────────────────
    function test_withdraw_depositorCannotPullAlone() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory selfSig = _sign(OTHER_PK, locker.withdrawDigest(1, dl));
        vm.prank(depositor);
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.withdraw(1, dl, selfSig);
        assertEq(nft.ownerOf(T1), address(locker));
    }

    function test_withdraw_withAdminSig_toDepositorOnly() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _withdrawSig(1, dl);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLocker.NotDepositor.selector);
        locker.withdraw(1, dl, sig);
        vm.prank(depositor);
        locker.withdraw(1, dl, sig);
        assertEq(nft.ownerOf(T1), depositor);
    }

    function test_releaseSigCannotBeUsedAsWithdraw() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory releaseSig = _releaseSig(1, depositor, dl);
        vm.prank(depositor);
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.withdraw(1, dl, releaseSig);
    }

    // ─── roles ──────────────────────────────────────────────────
    function test_setRoles_adminSigned_nonceReplayBlocked() public {
        address newKeeper = makeAddr("newKeeper");
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(ADMIN_PK, locker.rolesDigest(admin, newKeeper, depositor, dl));
        vm.prank(thief); // anyone may submit a valid admin-signed rotation
        locker.setRoles(admin, newKeeper, depositor, dl, sig);
        assertEq(locker.keeper(), newKeeper);
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.setRoles(admin, newKeeper, depositor, dl, sig); // nonce moved on
    }

    function test_setRoles_notAdminFails() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(OTHER_PK, locker.rolesDigest(admin, thief, thief, dl));
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.setRoles(admin, thief, thief, dl, sig);
    }

    function test_crossDeploymentReplayBlocked() public {
        PentagonPrizeLocker other = new PentagonPrizeLocker(admin, keeper, depositor);
        uint256 dl = block.timestamp + 1 hours;
        // a sig for the OTHER locker's lock 1 (same numbers) must not work here
        bytes32 d = keccak256(abi.encodePacked("\x19\x01", other.domainSeparator(), keccak256(abi.encode(
            locker.RELEASE_TYPEHASH(), uint256(1), address(nft), T1, winner, dl))));
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.release(1, winner, dl, _sign(ADMIN_PK, d));
    }
}
