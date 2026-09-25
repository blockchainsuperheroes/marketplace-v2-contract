// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PentagonPrizeLocker} from "../src/PrizeLocker.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MockAzuki is ERC721 {
    constructor() ERC721("Azuki", "AZUKI") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}


// Collection that, while the locker is checking it in, tries to push a DIFFERENT real NFT into
// the locker (the review's M-1 smuggling path).
contract EvilCollection {
    IERC721 public real;
    uint256 public realId;
    constructor(IERC721 real_, uint256 realId_) { real = real_; realId = realId_; }
    function safeTransferFrom(address, address to, uint256) external { real.safeTransferFrom(address(this), to, realId); }
    function ownerOf(uint256) external view returns (address) { return address(this); }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }
}

// Minimal ERC-1271 "multisig": approves any digest its owner key signed.
contract MockSafe {
    address public signer;
    constructor(address s) { signer = s; }
    function isValidSignature(bytes32 h, bytes calldata sig) external view returns (bytes4) {
        (address r,,) = ECDSA.tryRecover(h, sig);
        return r == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

// The review's H-1 PoC: rotate itself in as keeper and release in ONE transaction.
contract AdminDrainer {
    function drain(PentagonPrizeLocker l, address admin, address depositor, uint256 dl, bytes calldata rolesSig,
                   uint256 lockId, address to, bytes calldata relSig) external {
        l.proposeRoles(admin, address(this), depositor, dl, rolesSig);
        l.executeRoles("");
        l.release(lockId, to, dl, relSig);
    }
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
        (address c, uint256 id, address dep, PentagonPrizeLocker.Status st) = locker.locks(1);
        assertEq(c, address(nft));
        assertEq(id, T1);
        assertEq(dep, depositor);
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
        vm.expectRevert(PentagonPrizeLocker.UnexpectedTransfer.selector);
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

    // ─── roles: propose → 48h → execute ─────────────────────────
    function _propose(address a, address k, address d) internal {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(ADMIN_PK, locker.proposeRolesDigest(a, k, d, dl));
        locker.proposeRoles(a, k, d, dl, sig);
    }

    function test_roles_delayEnforced_thenAnyoneExecutes() public {
        address newKeeper = makeAddr("newKeeper");
        _propose(admin, newKeeper, depositor);
        vm.expectRevert(PentagonPrizeLocker.TooEarly.selector);
        locker.executeRoles("");
        assertEq(locker.keeper(), keeper, "old keeper until the delay passes");
        vm.warp(block.timestamp + 48 hours);
        vm.prank(thief);
        locker.executeRoles("");
        assertEq(locker.keeper(), newKeeper);
    }

    function test_roles_proposalVoidsOutstandingSigs() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _releaseSig(1, winner, dl); // signed under nonce 0
        _propose(admin, makeAddr("k2"), depositor);    // nonce -> 1
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.release(1, winner, dl, sig);
    }

    function test_roles_adminAloneCannotDrainInOneTx() public {
        AdminDrainer d = new AdminDrainer();
        uint256 dl = block.timestamp + 1 hours;
        bytes memory rs = _sign(ADMIN_PK, locker.proposeRolesDigest(admin, address(d), depositor, dl));
        bytes memory rel = _releaseSig(1, thief, dl);
        vm.expectRevert(); // TooEarly: the 48h public delay blocks it
        d.drain(locker, admin, depositor, dl, rs, 1, thief, rel);
        assertEq(nft.ownerOf(T1), address(locker));
    }

    function test_roles_mustBeDistinct() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(ADMIN_PK, locker.proposeRolesDigest(admin, admin, depositor, dl));
        vm.expectRevert(PentagonPrizeLocker.RolesNotDistinct.selector);
        locker.proposeRoles(admin, admin, depositor, dl, sig);
        vm.expectRevert(PentagonPrizeLocker.RolesNotDistinct.selector);
        new PentagonPrizeLocker(admin, keeper, keeper);
    }

    function test_roles_notAdminFails() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(OTHER_PK, locker.proposeRolesDigest(admin, thief, depositor, dl));
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.proposeRoles(admin, thief, depositor, dl, sig);
    }

    function test_roles_newAdminMustCoSign_thenSafeAdminWorks() public {
        uint256 SAFE_OWNER_PK = 0x5AFE;
        MockSafe safe = new MockSafe(vm.addr(SAFE_OWNER_PK));
        _propose(address(safe), keeper, depositor);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(PentagonPrizeLocker.BadNewAdminSig.selector);
        locker.executeRoles(hex"00"); // garbage co-signature: a dead or typo'd admin can't be set
        bytes memory accept = _sign(SAFE_OWNER_PK, locker.acceptAdminDigest(address(safe)));
        locker.executeRoles(accept);
        assertEq(locker.admin(), address(safe));
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(SAFE_OWNER_PK, locker.releaseDigest(1, winner, dl));
        vm.prank(keeper);
        locker.release(1, winner, dl, sig); // the multisig (ERC-1271) approves a release
        assertEq(nft.ownerOf(T1), winner);
    }

    function test_roles_cancel() public {
        _propose(admin, makeAddr("k3"), depositor);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory c = _sign(ADMIN_PK, locker.cancelRolesDigest(dl));
        locker.cancelRoles(dl, c);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(PentagonPrizeLocker.NothingPending.selector);
        locker.executeRoles("");
    }

    // ─── review M-1 / L-2 regressions ───────────────────────────
    function test_strayTransferFrom_isAdopted() public {
        nft.mint(depositor, 99);
        vm.prank(depositor);
        nft.transferFrom(depositor, address(locker), 99); // no callback: would have been stuck
        vm.prank(depositor);
        uint256 id = locker.checkIn(address(nft), 99);
        assertEq(locker.lockOf(address(nft), 99), id);
    }

    function test_evilCollectionCannotSmuggleRealToken() public {
        EvilCollection evil = new EvilCollection(IERC721(address(nft)), 55);
        nft.mint(address(evil), 55);
        vm.prank(depositor);
        vm.expectRevert(); // UnexpectedTransfer: wrong collection/tokenId in the callback
        locker.checkIn(address(evil), 1);
        assertEq(nft.ownerOf(55), address(evil));
    }

    function test_withdrawGoesToOriginalDepositor() public {
        address newDep = makeAddr("newDepositor");
        _propose(admin, keeper, newDep);
        vm.warp(block.timestamp + 48 hours);
        locker.executeRoles("");
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _withdrawSig(1, dl);
        vm.prank(newDep); // only the CURRENT depositor may request...
        locker.withdraw(1, dl, sig);
        assertEq(nft.ownerOf(T1), depositor, "...but it returns to whoever checked it in");
    }

    function test_releaseDigest_matchesWalletTypedData() public view {
        string memory j = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"Release":[{"name":"lockId","type":"uint256"},{"name":"collection","type":"address"},{"name":"tokenId","type":"uint256"},{"name":"to","type":"address"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},',
            '"primaryType":"Release","domain":{"name":"PentagonPrizeLocker","version":"1","chainId":', vm.toString(block.chainid),
            ',"verifyingContract":"', vm.toString(address(locker)), '"},"message":{"lockId":1,"collection":"', vm.toString(address(nft)),
            '","tokenId":', vm.toString(T1), ',"to":"', vm.toString(winner), '","nonce":0,"deadline":1000}}');
        assertEq(vm.eip712HashTypedData(j), locker.releaseDigest(1, winner, 1000));
    }

    function test_crossDeploymentReplayBlocked() public {
        PentagonPrizeLocker other = new PentagonPrizeLocker(admin, keeper, depositor);
        uint256 dl = block.timestamp + 1 hours;
        bytes32 d = keccak256(abi.encodePacked("\x19\x01", other.domainSeparator(), keccak256(abi.encode(
            locker.RELEASE_TYPEHASH(), uint256(1), address(nft), T1, winner, uint256(0), dl))));
        bytes memory sig = _sign(ADMIN_PK, d);
        vm.prank(keeper);
        vm.expectRevert(PentagonPrizeLocker.BadAdminSig.selector);
        locker.release(1, winner, dl, sig);
    }
}
