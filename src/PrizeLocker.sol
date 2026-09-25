// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PentagonPrizeLocker — Ethereum lock for Points Store prizes
/// @notice Public, verifiable custody for the NFTs offered in the Pentagon Points Store. Anyone can
///         check on-chain that a prize is here and under these rules:
///           • CHECK-IN: only the depositor can check an NFT in (direct transfers are rejected, so
///             nothing can land here unregistered).
///           • RELEASE to a winner: only the keeper can submit it, and only with a Pentagon-admin
///             EIP-712 signature naming that exact lock, recipient and deadline.
///           • WITHDRAW back to the depositor: only the depositor can submit it, and also only with
///             a Pentagon-admin signature. The depositor cannot pull a prize back alone.
///         Each lock moves out exactly once. There is no owner, no upgrade, no arbitrary call, no
///         ETH handling — the rules above are the whole contract.
/// @dev NON-upgradeable on purpose: an upgrade key could rewrite the rules, which would defeat the
///      point of a lock users can verify. Role changes are signed by the current admin.
///      ⚠ UNAUDITED.
contract PentagonPrizeLocker is EIP712, IERC721Receiver, ReentrancyGuard {
    enum Status { None, Locked, Released, Withdrawn }

    struct Lock {
        address collection;
        uint256 tokenId;
        Status status;
    }

    bytes32 public constant RELEASE_TYPEHASH =
        keccak256("Release(uint256 lockId,address collection,uint256 tokenId,address to,uint256 deadline)");
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(uint256 lockId,address collection,uint256 tokenId,uint256 deadline)");
    bytes32 public constant ROLES_TYPEHASH =
        keccak256("SetRoles(address admin,address keeper,address depositor,uint256 nonce,uint256 deadline)");
    /// Admin signatures are made on a hardware wallet by a human — 48h is enough and bounds the
    /// window in which a signature can be used.
    uint256 public constant MAX_DEADLINE = 48 hours;

    address public admin; // Pentagon admin: signs every transfer out (never needs gas here)
    address public keeper; // submits releases
    address public depositor; // checks prizes in; may request a withdraw
    uint256 public rolesNonce;

    uint256 public lockCount;
    mapping(uint256 => Lock) public locks;
    /// (collection, tokenId) → lockId while locked (0 = not locked). Lets anyone look a prize up.
    mapping(address => mapping(uint256 => uint256)) public lockOf;

    bool private _checkingIn;

    event RolesSet(address admin, address keeper, address depositor);
    event CheckedIn(uint256 indexed lockId, address indexed collection, uint256 indexed tokenId);
    event Released(uint256 indexed lockId, address indexed collection, uint256 indexed tokenId, address to);
    event Withdrawn(uint256 indexed lockId, address indexed collection, uint256 indexed tokenId, address to);

    error ZeroAddress();
    error NotKeeper();
    error NotDepositor();
    error NotLocked();
    error AlreadyLocked();
    error BadRecipient();
    error Expired();
    error DeadlineTooFar();
    error BadAdminSig();
    error DirectTransferRejected();

    constructor(address admin_, address keeper_, address depositor_) EIP712("PentagonPrizeLocker", "1") {
        _setRoles(admin_, keeper_, depositor_);
    }

    // ─── Check-in (depositor) ───────────────────────────────────
    /// @notice Pulls `tokenId` from the depositor into the lock. Depositor must approve first.
    function checkIn(address collection, uint256 tokenId) external nonReentrant returns (uint256 lockId) {
        if (msg.sender != depositor) revert NotDepositor();
        if (collection == address(0)) revert ZeroAddress();
        if (lockOf[collection][tokenId] != 0) revert AlreadyLocked();
        lockId = ++lockCount;
        locks[lockId] = Lock({collection: collection, tokenId: tokenId, status: Status.Locked});
        lockOf[collection][tokenId] = lockId;
        _checkingIn = true;
        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);
        _checkingIn = false;
        if (IERC721(collection).ownerOf(tokenId) != address(this)) revert NotLocked();
        emit CheckedIn(lockId, collection, tokenId);
    }

    // ─── Release to a winner (keeper + admin signature) ─────────
    function release(uint256 lockId, address to, uint256 deadline, bytes calldata adminSig) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        if (to == address(0) || to == address(this)) revert BadRecipient();
        Lock storage l = _live(lockId);
        _checkDeadline(deadline);
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(RELEASE_TYPEHASH, lockId, l.collection, l.tokenId, to, deadline)));
        if (ECDSA.recover(digest, adminSig) != admin) revert BadAdminSig();
        l.status = Status.Released;
        lockOf[l.collection][l.tokenId] = 0;
        IERC721(l.collection).safeTransferFrom(address(this), to, l.tokenId);
        emit Released(lockId, l.collection, l.tokenId, to);
    }

    // ─── Withdraw back to the depositor (depositor + admin signature) ──
    function withdraw(uint256 lockId, uint256 deadline, bytes calldata adminSig) external nonReentrant {
        if (msg.sender != depositor) revert NotDepositor();
        Lock storage l = _live(lockId);
        _checkDeadline(deadline);
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(WITHDRAW_TYPEHASH, lockId, l.collection, l.tokenId, deadline)));
        if (ECDSA.recover(digest, adminSig) != admin) revert BadAdminSig();
        l.status = Status.Withdrawn;
        lockOf[l.collection][l.tokenId] = 0;
        IERC721(l.collection).safeTransferFrom(address(this), depositor, l.tokenId);
        emit Withdrawn(lockId, l.collection, l.tokenId, depositor);
    }

    // ─── Role rotation (signed by the CURRENT admin; anyone may submit) ──
    function setRoles(address admin_, address keeper_, address depositor_, uint256 deadline, bytes calldata adminSig) external {
        _checkDeadline(deadline);
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(ROLES_TYPEHASH, admin_, keeper_, depositor_, rolesNonce, deadline)));
        if (ECDSA.recover(digest, adminSig) != admin) revert BadAdminSig();
        rolesNonce++;
        _setRoles(admin_, keeper_, depositor_);
    }

    // ─── Views / helpers ────────────────────────────────────────
    function releaseDigest(uint256 lockId, address to, uint256 deadline) external view returns (bytes32) {
        Lock storage l = locks[lockId];
        return _hashTypedDataV4(keccak256(abi.encode(RELEASE_TYPEHASH, lockId, l.collection, l.tokenId, to, deadline)));
    }

    function withdrawDigest(uint256 lockId, uint256 deadline) external view returns (bytes32) {
        Lock storage l = locks[lockId];
        return _hashTypedDataV4(keccak256(abi.encode(WITHDRAW_TYPEHASH, lockId, l.collection, l.tokenId, deadline)));
    }

    function rolesDigest(address admin_, address keeper_, address depositor_, uint256 deadline) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ROLES_TYPEHASH, admin_, keeper_, depositor_, rolesNonce, deadline)));
    }

    function domainSeparator() external view returns (bytes32) { return _domainSeparatorV4(); }

    /// Only accepts NFTs arriving through checkIn(); anything else would be unregistered.
    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (!_checkingIn) revert DirectTransferRejected();
        return IERC721Receiver.onERC721Received.selector;
    }

    // ─── Internal ───────────────────────────────────────────────
    function _live(uint256 lockId) internal view returns (Lock storage l) {
        l = locks[lockId];
        if (l.status != Status.Locked) revert NotLocked();
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert Expired();
        if (deadline > block.timestamp + MAX_DEADLINE) revert DeadlineTooFar();
    }

    function _setRoles(address admin_, address keeper_, address depositor_) internal {
        if (admin_ == address(0) || keeper_ == address(0) || depositor_ == address(0)) revert ZeroAddress();
        admin = admin_;
        keeper = keeper_;
        depositor = depositor_;
        emit RolesSet(admin_, keeper_, depositor_);
    }
}
