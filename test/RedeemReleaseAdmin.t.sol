// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RedeemReleaseAdmin} from "../src/RedeemReleaseAdmin.sol";
import {PentagonPrizeLockerOpen} from "../src/PrizeLockerOpen.sol";
import {PentagonPrizeLocker} from "../src/PrizeLocker.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockPrize is ERC721 {
    constructor() ERC721("Prize", "PRZ") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract SomeContract {}

contract RedeemReleaseAdminTest is Test {
    uint256 constant HUMAN_PK = 0xB2E3;
    uint256 constant VERIFIER_PK = 0x7E41;
    uint256 constant ATTACKER_PK = 0xBAD;
    address human = vm.addr(HUMAN_PK);
    address verifier = vm.addr(VERIFIER_PK);
    address keeper = makeAddr("keeper");
    address seller = makeAddr("seller");
    address winner = makeAddr("winner");

    MockPrize nft;
    PentagonPrizeLockerOpen open;
    PentagonPrizeLocker own;
    RedeemReleaseAdmin ra;
    uint256 lockId;

    function setUp() public {
        nft = new MockPrize();
        // Today's live setup: the human wallet is the admin.
        open = new PentagonPrizeLockerOpen(human, keeper);
        own = new PentagonPrizeLocker(human, keeper, seller);
        ra = new RedeemReleaseAdmin(human, verifier, address(open), address(own));

        nft.mint(seller, 1);
        nft.mint(seller, 2);
        nft.mint(seller, 3);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(open), true);
        nft.setApprovalForAll(address(own), true);
        lockId = open.checkIn(address(nft), 1, address(0));
        open.checkIn(address(nft), 2, address(0));
        vm.stopPrank();

        _handOver();
    }

    function _sign(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    /// The real handover: human proposes the new admin, 48h public delay, human co-signs as the new admin.
    function _handOver() internal {
        uint256 dl = block.timestamp + 1 hours;
        open.proposeRoles(address(ra), keeper, dl, _sign(HUMAN_PK, open.proposeRolesDigest(address(ra), keeper, dl)));
        vm.warp(block.timestamp + 48 hours);
        open.executeRoles(_sign(HUMAN_PK, open.acceptAdminDigest(address(ra))));
        assertEq(open.admin(), address(ra));
    }

    function _autoSig(address locker, uint256 id, address to, uint256 dl, uint256 pk) internal view returns (bytes memory) {
        bytes32 rd = PentagonPrizeLockerOpen(locker).releaseDigest(id, to, dl);
        return abi.encode(id, to, dl, _sign(pk, ra.autoReleaseDigest(locker, rd)));
    }

    function test_autoRelease_keeperPlusVerifier() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _autoSig(address(open), lockId, winner, dl, VERIFIER_PK);
        vm.prank(keeper);
        open.release(lockId, winner, dl, sig);
        assertEq(nft.ownerOf(1), winner);
    }

    function test_autoRelease_needsTheKeeperToSubmit() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _autoSig(address(open), lockId, winner, dl, VERIFIER_PK);
        vm.prank(winner);
        vm.expectRevert(PentagonPrizeLockerOpen.NotKeeper.selector);
        open.release(lockId, winner, dl, sig);
    }

    function test_autoRelease_rejectsAnyOtherSigner() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _autoSig(address(open), lockId, winner, dl, ATTACKER_PK);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLockerOpen.BadAdminSig.selector);
        open.release(lockId, winner, dl, sig);
    }

    function test_autoSig_boundToItsLockAndRecipient() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _autoSig(address(open), lockId, winner, dl, VERIFIER_PK);
        vm.startPrank(keeper);
        vm.expectRevert(PentagonPrizeLockerOpen.BadAdminSig.selector);
        open.release(lockId, makeAddr("thief"), dl, sig); // other recipient
        vm.expectRevert(PentagonPrizeLockerOpen.BadAdminSig.selector);
        open.release(lockId + 1, winner, dl, sig); // other lock
        vm.stopPrank();
    }

    function test_autoSig_cannotWithdrawOrChangeRoles() public {
        uint256 dl = block.timestamp + 1 hours;
        // Verifier signs whatever it is handed, in the AUTO format: still useless outside a release.
        bytes32 wd = open.withdrawDigest(lockId, dl);
        bytes memory w = abi.encode(lockId, seller, dl, _sign(VERIFIER_PK, ra.autoReleaseDigest(address(open), wd)));
        vm.prank(seller);
        vm.expectRevert(PentagonPrizeLockerOpen.BadAdminSig.selector);
        open.withdraw(lockId, dl, w);

        address evil = makeAddr("evil");
        bytes32 pd = open.proposeRolesDigest(evil, evil, dl);
        bytes memory p = abi.encode(lockId, winner, dl, _sign(VERIFIER_PK, ra.autoReleaseDigest(address(open), pd)));
        vm.expectRevert(PentagonPrizeLockerOpen.BadAdminSig.selector);
        open.proposeRoles(evil, keeper, dl, p);
    }

    function test_autoRelease_refusesContractRecipient() public {
        address c = address(new SomeContract());
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _autoSig(address(open), lockId, c, dl, VERIFIER_PK);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLockerOpen.BadAdminSig.selector);
        open.release(lockId, c, dl, sig);
    }

    function test_pause_stopsAutoButNotHuman() public {
        vm.prank(verifier);
        vm.expectRevert(RedeemReleaseAdmin.NotHuman.selector);
        ra.setAutoPaused(true);
        vm.prank(human);
        ra.setAutoPaused(true);

        uint256 dl = block.timestamp + 1 hours;
        bytes memory auto_ = _autoSig(address(open), lockId, winner, dl, VERIFIER_PK);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLockerOpen.BadAdminSig.selector);
        open.release(lockId, winner, dl, auto_);

        bytes memory manual = _sign(HUMAN_PK, open.releaseDigest(lockId, winner, dl));
        vm.prank(keeper);
        open.release(lockId, winner, dl, manual);
        assertEq(nft.ownerOf(1), winner);
    }

    function test_human_keepsEveryAdminPower() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory w = _sign(HUMAN_PK, open.withdrawDigest(lockId, dl));
        vm.prank(seller);
        open.withdraw(lockId, dl, w);
        assertEq(nft.ownerOf(1), seller);

        address next = makeAddr("nextKeeper");
        open.proposeRoles(address(ra), next, dl, _sign(HUMAN_PK, open.proposeRolesDigest(address(ra), next, dl)));
        (, address k,) = open.pending();
        assertEq(k, next);
    }

    function test_autoSig_onlyFromListedLockers() public {
        PentagonPrizeLockerOpen other = new PentagonPrizeLockerOpen(address(ra), keeper);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(other), true);
        uint256 id = other.checkIn(address(nft), 3, address(0));
        vm.stopPrank();
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _autoSig(address(other), id, winner, dl, VERIFIER_PK);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLockerOpen.BadAdminSig.selector);
        other.release(id, winner, dl, sig);
    }

    function test_worksOnPentagonsOwnPrizeLockerToo() public {
        uint256 dl = block.timestamp + 1 hours;
        own.proposeRoles(address(ra), keeper, seller, dl, _sign(HUMAN_PK, own.proposeRolesDigest(address(ra), keeper, seller, dl)));
        vm.warp(vm.getBlockTimestamp() + 48 hours); // via_ir caches block.timestamp across warps
        own.executeRoles(_sign(HUMAN_PK, own.acceptAdminDigest(address(ra))));

        vm.prank(seller);
        uint256 id = own.checkIn(address(nft), 3);
        dl = vm.getBlockTimestamp() + 1 hours;
        bytes32 rd = own.releaseDigest(id, winner, dl);
        bytes memory sig = abi.encode(id, winner, dl, _sign(VERIFIER_PK, ra.autoReleaseDigest(address(own), rd)));
        vm.prank(keeper);
        own.release(id, winner, dl, sig);
        assertEq(nft.ownerOf(3), winner);
    }
}
