// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

interface IReleaseDigest {
    function releaseDigest(uint256 lockId, address to, uint256 deadline) external view returns (bytes32);
}

/// @title RedeemReleaseAdmin — ERC-1271 admin for the Redeem prize lockers, adding automatic release
/// @notice Becomes the `admin` of PentagonPrizeLocker / PentagonPrizeLockerOpen (via their public 48h
///         role change). It accepts two kinds of signature:
///           • HUMAN: a plain 65-byte signature from `human` (nftprof's wallet) over any digest —
///             everything the admin could do before, unchanged (manual releases, withdrawals, role changes).
///           • AUTO: a release the independent verifier has signed. Valid ONLY when the digest is exactly
///             that locker's `releaseDigest(lockId, to, deadline)`, so it can never authorize a withdrawal,
///             a role change or anything else. The lockers only accept a release submitted by their
///             keeper, so an auto release needs both the keeper (sender) and the verifier (signature).
///         The verifier signs only after re-reading the claim itself: paid in PC at the listed price,
///         unreleased 72h after the claim, delivery address a plain wallet. Off-chain rules; on-chain we
///         additionally refuse a recipient that has code here.
///         `human` can switch AUTO off instantly, or veto it for one lock (the 72h wait is the window to
///         do so). Nothing about this contract can change except those two switches: changing the
///         verifier means deploying a new admin and a public 48h role change on each locker.
contract RedeemReleaseAdmin is IERC1271, EIP712 {
    bytes4 private constant MAGIC = IERC1271.isValidSignature.selector;
    bytes4 private constant INVALID = 0xffffffff;
    bytes32 public constant AUTO_RELEASE_TYPEHASH = keccak256("AutoRelease(address locker,bytes32 releaseDigest)");

    address public immutable human;
    address public immutable verifier;
    address public immutable lockerA;
    address public immutable lockerB;
    bool public autoPaused;
    /// locker => lockId => auto release vetoed by `human`
    mapping(address => mapping(uint256 => bool)) public vetoed;

    event AutoPaused(bool paused);
    event Vetoed(address indexed locker, uint256 indexed lockId, bool vetoed);

    error NotHuman();
    error ZeroAddress();

    constructor(address human_, address verifier_, address lockerA_, address lockerB_)
        EIP712("PentagonRedeemRelease", "1")
    {
        if (human_ == address(0) || verifier_ == address(0) || lockerA_ == address(0)) revert ZeroAddress();
        human = human_;
        verifier = verifier_;
        lockerA = lockerA_;
        lockerB = lockerB_;
    }

    /// AUTO signature = abi.encode(lockId, to, deadline, verifierSig); HUMAN signature = 65 bytes.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length == 65) return _signer(hash, signature) == human ? MAGIC : INVALID;

        address locker = msg.sender; // SignatureChecker calls us from the locker itself
        if (autoPaused || (locker != lockerA && locker != lockerB)) return INVALID;
        (uint256 lockId, address to, uint256 deadline, bytes memory verifierSig) =
            abi.decode(signature, (uint256, address, uint256, bytes));
        if (vetoed[locker][lockId] || to.code.length != 0) return INVALID;
        if (IReleaseDigest(locker).releaseDigest(lockId, to, deadline) != hash) return INVALID;
        return _signer(autoReleaseDigest(locker, hash), verifierSig) == verifier ? MAGIC : INVALID;
    }

    /// What the verifier signs for one release.
    function autoReleaseDigest(address locker, bytes32 releaseDigest) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(AUTO_RELEASE_TYPEHASH, locker, releaseDigest)));
    }

    function setAutoPaused(bool paused) external {
        if (msg.sender != human) revert NotHuman();
        autoPaused = paused;
        emit AutoPaused(paused);
    }

    function setVetoed(address locker, uint256 lockId, bool veto) external {
        if (msg.sender != human) revert NotHuman();
        vetoed[locker][lockId] = veto;
        emit Vetoed(locker, lockId, veto);
    }

    function _signer(bytes32 digest, bytes memory sig) internal pure returns (address signer) {
        (signer,,) = ECDSA.tryRecover(digest, sig);
    }
}
