// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTPrizeVault} from "../src/NFTPrizeVault.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

contract MockNFT is ERC721 {
    constructor() ERC721("Azuki", "AZUKI") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract NFTPrizeVaultTest is Test {
    NFTPrizeVault vault;
    MockNFT nft;

    uint256 constant KEEPER_PK = 0xA11CE;
    uint256 constant VERIFIER_PK = 0xB0B;
    uint256 constant ATTACKER_PK = 0xBAD;
    address keeper = vm.addr(KEEPER_PK);
    address verifier = vm.addr(VERIFIER_PK);

    address owner = makeAddr("owner");
    address winner = makeAddr("winner");
    uint256 constant SRC_CHAIN = 3344;
    address srcDrops = makeAddr("pentagonVaultDrops");
    bytes32 settleTx = keccak256("DropSettled tx");

    uint256 constant DROP = 7;
    uint256 constant TOKEN = 1234;

    function setUp() public {
        nft = new MockNFT();
        vault = new NFTPrizeVault(owner, keeper, verifier, SRC_CHAIN, srcDrops);
        nft.mint(owner, TOKEN);
        vm.startPrank(owner);
        nft.setApprovalForAll(address(vault), true);
        vault.deposit(DROP, address(nft), TOKEN);
        vm.stopPrank();
    }

    // ─── helpers ────────────────────────────────────────────────
    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _digest(address w, uint256 deadline) internal view returns (bytes32) {
        return vault.releaseDigest(DROP, address(nft), TOKEN, w, settleTx, deadline);
    }

    function _attest(address w, uint256 deadline) internal view returns (bytes memory k, bytes memory v) {
        bytes32 d = _digest(w, deadline);
        return (_sign(KEEPER_PK, d), _sign(VERIFIER_PK, d));
    }

    function _release(address w, uint256 deadline, bytes memory k, bytes memory v) internal {
        vm.prank(owner);
        vault.release(DROP, w, settleTx, deadline, k, v);
    }

    // ─── deposit ────────────────────────────────────────────────
    function test_deposit_bindsPrize() public view {
        (address c, uint256 id, bool dep, bool rel, bool dead) = vault.prizes(DROP);
        assertEq(c, address(nft));
        assertEq(id, TOKEN);
        assertTrue(dep);
        assertFalse(rel);
        assertFalse(dead);
        assertEq(nft.ownerOf(TOKEN), address(vault));
        assertTrue(vault.isReleasable(DROP));
    }

    function test_deposit_rejectsReusedDropAndToken() public {
        nft.mint(owner, 2);
        vm.startPrank(owner);
        vm.expectRevert(NFTPrizeVault.AlreadyUsed.selector);
        vault.deposit(DROP, address(nft), 2);
        // token already bound to DROP — can't bind to another drop
        vm.expectRevert(); // ERC721 transfer fails (vault owns it) or Bound — either way rejected
        vault.deposit(8, address(nft), TOKEN);
        vm.stopPrank();
    }

    function test_deposit_onlyOwner() public {
        vm.prank(winner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, winner));
        vault.deposit(9, address(nft), 5);
    }

    // ─── release happy path ─────────────────────────────────────
    function test_release_twoOfTwo_ownerSubmitted() public {
        uint256 deadline = block.timestamp + 24 hours;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        vm.expectEmit(true, true, true, true);
        emit NFTPrizeVault.Released(DROP, address(nft), TOKEN, winner, settleTx);
        _release(winner, deadline, k, v);
        assertEq(nft.ownerOf(TOKEN), winner);
        (,,, bool rel,) = vault.prizes(DROP);
        assertTrue(rel);
        assertFalse(vault.isReleasable(DROP));
    }

    // ─── replay / signature guards ──────────────────────────────
    function test_release_replayBlocked() public {
        uint256 deadline = block.timestamp + 24 hours;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        _release(winner, deadline, k, v);
        // winner sends it back to the vault (stray) — same attestation must not fire again
        vm.prank(winner);
        nft.transferFrom(winner, address(vault), TOKEN);
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.AlreadyReleased.selector);
        vault.release(DROP, winner, settleTx, deadline, k, v);
    }

    function test_release_keeperAloneFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 d = _digest(winner, deadline);
        bytes memory k = _sign(KEEPER_PK, d);
        // keeper signing twice ≠ verifier
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.BadVerifierSig.selector);
        vault.release(DROP, winner, settleTx, deadline, k, k);
    }

    function test_release_swappedSigsFail() public {
        uint256 deadline = block.timestamp + 1 hours;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.BadKeeperSig.selector);
        vault.release(DROP, winner, settleTx, deadline, v, k);
    }

    function test_release_forgedVerifierFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 d = _digest(winner, deadline);
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.BadVerifierSig.selector);
        vault.release(DROP, winner, settleTx, deadline, _sign(KEEPER_PK, d), _sign(ATTACKER_PK, d));
    }

    function test_release_tamperedWinnerFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        address thief = makeAddr("thief");
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.BadKeeperSig.selector);
        vault.release(DROP, thief, settleTx, deadline, k, v);
    }

    function test_release_attestationForOtherVaultFails() public {
        // Same signers, different SRC_CONTRACT → different digest → no replay across deployments.
        NFTPrizeVault other = new NFTPrizeVault(owner, keeper, verifier, SRC_CHAIN, makeAddr("otherDrops"));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 d = other.releaseDigest(DROP, address(nft), TOKEN, winner, settleTx, deadline);
        assertTrue(d != _digest(winner, deadline));
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.BadKeeperSig.selector);
        vault.release(DROP, winner, settleTx, deadline, _sign(KEEPER_PK, d), _sign(VERIFIER_PK, d));
    }

    function test_release_malformedSigReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(owner);
        vm.expectRevert(); // ECDSA.recover reverts on bad length — never address(0)
        vault.release(DROP, winner, settleTx, deadline, hex"deadbeef", hex"deadbeef");
    }

    // ─── deadline ───────────────────────────────────────────────
    function test_release_expiredFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        vm.warp(deadline + 1);
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.Expired.selector);
        vault.release(DROP, winner, settleTx, deadline, k, v);
    }

    function test_release_deadlineTooFarFails() public {
        uint256 deadline = block.timestamp + 48 hours + 1;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.DeadlineTooFar.selector);
        vault.release(DROP, winner, settleTx, deadline, k, v);
    }

    function test_release_deadlineExactly48hOk() public {
        uint256 deadline = block.timestamp + 48 hours;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        _release(winner, deadline, k, v);
        assertEq(nft.ownerOf(TOKEN), winner);
    }

    // ─── winner / role / state guards ───────────────────────────
    function test_release_zeroOrVaultWinnerFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        (bytes memory k, bytes memory v) = _attest(address(0), deadline);
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.BadWinner.selector);
        vault.release(DROP, address(0), settleTx, deadline, k, v);
        (k, v) = _attest(address(vault), deadline);
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.BadWinner.selector);
        vault.release(DROP, address(vault), settleTx, deadline, k, v);
    }

    function test_release_notOwnerFails_evenWithValidAttestation() public {
        uint256 deadline = block.timestamp + 1 hours;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        vm.prank(keeper); // the keeper itself cannot execute — 3rd key required
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.release(DROP, winner, settleTx, deadline, k, v);
        assertEq(nft.ownerOf(TOKEN), address(vault));
    }

    function test_release_pausedFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.release(DROP, winner, settleTx, deadline, k, v);
        assertFalse(vault.isReleasable(DROP));
        vm.prank(owner);
        vault.unpause();
        _release(winner, deadline, k, v);
        assertEq(nft.ownerOf(TOKEN), winner);
    }

    function test_release_undepositedFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 d = vault.releaseDigest(99, address(nft), TOKEN, winner, settleTx, deadline);
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.NotDeposited.selector);
        vault.release(99, winner, settleTx, deadline, _sign(KEEPER_PK, d), _sign(VERIFIER_PK, d));
    }

    // ─── invalidate / reclaim (3rd-key escape) ──────────────────
    function test_invalidate_returnsNftAndKillsDrop() public {
        uint256 deadline = block.timestamp + 1 hours;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        vm.prank(owner);
        vault.invalidate(DROP);
        assertEq(nft.ownerOf(TOKEN), owner);
        (,,,, bool dead) = vault.prizes(DROP);
        assertTrue(dead);
        // even a perfectly valid 2-of-2 can never release a dead drop
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.DropDead.selector);
        vault.release(DROP, winner, settleTx, deadline, k, v);
        // and the drop id is burned — cannot be re-deposited
        vm.startPrank(owner);
        vm.expectRevert(NFTPrizeVault.AlreadyUsed.selector);
        vault.deposit(DROP, address(nft), TOKEN);
        vm.stopPrank();
    }

    function test_invalidate_worksWhilePaused() public {
        vm.startPrank(owner);
        vault.pause();
        vault.invalidate(DROP);
        vm.stopPrank();
        assertEq(nft.ownerOf(TOKEN), owner);
    }

    function test_reclaim_sameAsInvalidate_flaggedReclaim() public {
        vm.expectEmit(true, true, true, true);
        emit NFTPrizeVault.Invalidated(DROP, address(nft), TOKEN, true);
        vm.prank(owner);
        vault.reclaim(DROP);
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.DropDead.selector);
        vault.invalidate(DROP);
    }

    function test_invalidate_afterReleaseFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        (bytes memory k, bytes memory v) = _attest(winner, deadline);
        _release(winner, deadline, k, v);
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.AlreadyReleased.selector);
        vault.invalidate(DROP);
    }

    function test_invalidate_onlyOwner() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.invalidate(DROP);
    }

    // ─── rescue: bound tokens are untouchable ───────────────────
    function test_rescue_boundTokenFails_strayOk() public {
        vm.prank(owner);
        vm.expectRevert(NFTPrizeVault.Bound.selector);
        vault.rescueUnbound(address(nft), TOKEN, owner);
        // stray send
        nft.mint(winner, 555);
        vm.prank(winner);
        nft.transferFrom(winner, address(vault), 555);
        vm.prank(owner);
        vault.rescueUnbound(address(nft), 555, winner);
        assertEq(nft.ownerOf(555), winner);
    }

    // ─── signers / ownership admin ──────────────────────────────
    function test_setSigners_rejectsZeroAndSame() public {
        vm.startPrank(owner);
        vm.expectRevert(NFTPrizeVault.ZeroAddress.selector);
        vault.setSigners(address(0), verifier);
        vm.expectRevert(NFTPrizeVault.SameSigner.selector);
        vault.setSigners(keeper, keeper);
        vault.setSigners(verifier, keeper); // rotation
        vm.stopPrank();
        assertEq(vault.keeper(), verifier);
    }

    function test_ownership_twoStep() public {
        address next = makeAddr("nextOwner");
        vm.prank(owner);
        vault.transferOwnership(next);
        assertEq(vault.owner(), owner); // not yet
        vm.prank(next);
        vault.acceptOwnership();
        assertEq(vault.owner(), next);
    }

    function test_domain_isPentagonVaultDrops_v1() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PentagonVaultDrops"),
                keccak256("1"),
                block.chainid,
                address(vault)
            )
        );
        assertEq(vault.domainSeparator(), expected);
    }
}
