// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PentagonPrizeLockerOpen — Ethereum lock for Points Store SELLER listings
/// @notice Public, verifiable custody for the NFTs offered in the Pentagon Points Store. Anyone can
///         check on-chain that a prize is here and under these rules:
///           • CHECK-IN: ANY holder can check in their NFT (pull via safeTransferFrom). Each lock records
///             its own depositor = the seller. (No stray-token adoption: with open check-in, adopting
///             whatever sits here would let anyone claim someone else's mistaken transfer.)
///           • RELEASE to a winner: only the keeper can submit it, and only with a Pentagon-admin
///             EIP-712 signature naming that exact lock, recipient, nonce and deadline.
///           • WITHDRAW back to its depositor: only that lock's depositor can submit it, and only with a
///             Pentagon-admin signature (the admin won't sign while a Points claim on it is open).
///           • ROLE CHANGES are public and delayed 48h (admin-signed proposal, anyone executes after
///             the delay; a new admin must co-sign). A proposal immediately voids every outstanding
///             release/withdraw signature.
///         There is no owner, no upgrade, no arbitrary call, no ETH handling.
/// @dev NON-upgradeable on purpose: an upgrade key could rewrite the rules. Admin signatures are
///      checked with SignatureChecker, so the admin may be an EOA/hardware wallet OR an ERC-1271
///      contract wallet (e.g. a Safe multisig).
///      TRUST NOTE: the admin key has full release authority over every locked NFT; the keeper and
///      the 48h role delay make any change of hands public and slow, not impossible. Losing the
///      admin key freezes the locker — use a multisig admin for large holdings.
///      ⚠ UNAUDITED.
contract PentagonPrizeLockerOpen is EIP712, IERC721Receiver, ReentrancyGuard {
    enum Status { None, Locked, Released, Withdrawn }

    struct Lock {
        address collection;
        uint256 tokenId;
        address depositor; // who checked it in — a withdraw only ever returns it here
        Status status;
        /// Pentagon address the depositor names to receive the sale proceeds (need not equal the
        /// depositor: covers smart-contract wallets and AA2 users). The keeper only pays a Pentagon
        /// listing whose seller equals this.
        address payout;
    }

    struct PendingRoles {
        address admin;
        address keeper;
        uint64 eta; // 0 = none pending
    }

    bytes32 public constant RELEASE_TYPEHASH =
        keccak256("Release(uint256 lockId,address collection,uint256 tokenId,address to,uint256 nonce,uint256 deadline)");
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(uint256 lockId,address collection,uint256 tokenId,address to,uint256 nonce,uint256 deadline)");
    bytes32 public constant PROPOSE_ROLES_TYPEHASH =
        keccak256("ProposeRoles(address admin,address keeper,uint256 nonce,uint256 deadline)");
    bytes32 public constant CANCEL_ROLES_TYPEHASH = keccak256("CancelRoles(uint256 nonce,uint256 deadline)");
    bytes32 public constant ACCEPT_ADMIN_TYPEHASH = keccak256("AcceptAdmin(address admin,uint256 nonce)");

    /// Admin signatures are made on a hardware wallet by a human — 48h is enough and bounds the
    /// window in which a signature can be used.
    uint256 public constant MAX_DEADLINE = 48 hours;
    /// Every role change sits in public view this long before it can take effect.
    uint256 public constant ROLE_DELAY = 48 hours;
    /// A proposal not executed within this long after its delay expires is dead (no stale keys).
    uint256 public constant ROLE_GRACE = 7 days;

    address public admin; // Pentagon admin: signs every transfer out (never needs gas here)
    address public keeper; // submits releases
    /// Bumped on every role proposal/cancel: voids all outstanding signatures at once.
    uint256 public nonce;
    PendingRoles public pending;

    uint256 public lockCount;
    mapping(uint256 => Lock) public locks;
    /// (collection, tokenId) → lockId while locked (0 = not locked). Lets anyone look a prize up.
    mapping(address => mapping(uint256 => uint256)) public lockOf;

    // The one transfer the locker is expecting during checkIn — anything else is refused.
    address private _expectCollection;
    uint256 private _expectTokenId;
    bool private _checkingIn;

    event RolesSet(address admin, address keeper);
    event RolesProposed(address admin, address keeper, uint64 eta);
    event RolesCancelled(uint256 nonce);
    event CheckedIn(uint256 indexed lockId, address indexed collection, uint256 indexed tokenId, address depositor);
    event PayoutSet(uint256 indexed lockId, address payout);
    event Released(uint256 indexed lockId, address indexed collection, uint256 indexed tokenId, address to);
    event Withdrawn(uint256 indexed lockId, address indexed collection, uint256 indexed tokenId, address to);

    error ZeroAddress();
    error RolesNotDistinct();
    error NotKeeper();
    error NotDepositor();
    error NotLocked();
    error AlreadyLocked();
    error BadRecipient();
    error Expired();
    error DeadlineTooFar();
    error BadAdminSig();
    error BadNewAdminSig();
    error NothingPending();
    error TooEarly();
    error UnexpectedTransfer();
    error NotHeld();
    error NotERC721();
    error ProposalExpired();

    constructor(address admin_, address keeper_) EIP712("PentagonPrizeLockerOpen", "1") {
        _setRoles(admin_, keeper_);
    }

    // ─── Check-in (any holder) ──────────────────────────────────
    /// @notice Pulls `tokenId` from the caller (approve first) and locks it with the caller as depositor.
    ///         `payout` = the Pentagon wallet that may list it and receive the proceeds (0 = the caller).
    function checkIn(address collection, uint256 tokenId, address payout) external nonReentrant returns (uint256 lockId) {
        if (collection == address(0)) revert ZeroAddress();
        if (lockOf[collection][tokenId] != 0) revert AlreadyLocked();
        // Only standard ERC-721s: release/withdraw use safeTransferFrom.
        try IERC165(collection).supportsInterface(0x80ac58cd) returns (bool ok) {
            if (!ok) revert NotERC721();
        } catch {
            revert NotERC721();
        }
        if (IERC721(collection).ownerOf(tokenId) != msg.sender) revert NotHeld();
        lockId = ++lockCount;
        address p = payout == address(0) ? msg.sender : payout;
        locks[lockId] = Lock({collection: collection, tokenId: tokenId, depositor: msg.sender, status: Status.Locked, payout: p});
        lockOf[collection][tokenId] = lockId;
        _expectCollection = collection;
        _expectTokenId = tokenId;
        _checkingIn = true;
        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);
        _checkingIn = false;
        _expectCollection = address(0);
        _expectTokenId = 0;
        if (IERC721(collection).ownerOf(tokenId) != address(this)) revert NotHeld();
        emit CheckedIn(lockId, collection, tokenId, msg.sender);
        emit PayoutSet(lockId, p);
    }

    // ─── Release to a winner (keeper + admin signature) ─────────
    function release(uint256 lockId, address to, uint256 deadline, bytes calldata adminSig) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        if (to == address(0) || to == address(this)) revert BadRecipient();
        Lock storage l = _live(lockId);
        _checkDeadline(deadline);
        _requireAdmin(releaseDigest(lockId, to, deadline), adminSig);
        l.status = Status.Released;
        lockOf[l.collection][l.tokenId] = 0;
        // safeTransferFrom already guarantees delivery (recipient contracts must accept it); no
        // ownerOf re-check, so wallets that forward the NFT on arrival still work.
        IERC721(l.collection).safeTransferFrom(address(this), to, l.tokenId);
        emit Released(lockId, l.collection, l.tokenId, to);
    }

    // ─── Withdraw back to its depositor (depositor + admin signature) ──
    function withdraw(uint256 lockId, uint256 deadline, bytes calldata adminSig) external nonReentrant {
        Lock storage l = _live(lockId);
        if (msg.sender != l.depositor) revert NotDepositor();
        _checkDeadline(deadline);
        _requireAdmin(withdrawDigest(lockId, deadline), adminSig);
        l.status = Status.Withdrawn;
        lockOf[l.collection][l.tokenId] = 0;
        IERC721(l.collection).safeTransferFrom(address(this), l.depositor, l.tokenId);
        if (IERC721(l.collection).ownerOf(l.tokenId) != l.depositor) revert NotHeld();
        emit Withdrawn(lockId, l.collection, l.tokenId, l.depositor);
    }

    // ─── Role changes: admin-signed proposal → public 48h delay → execute ──
    function proposeRoles(address admin_, address keeper_, uint256 deadline, bytes calldata adminSig) external {
        _checkDeadline(deadline);
        _requireAdmin(proposeRolesDigest(admin_, keeper_, deadline), adminSig);
        _validateRoles(admin_, keeper_);
        nonce++; // voids every outstanding release/withdraw signature immediately
        uint64 eta = uint64(block.timestamp + ROLE_DELAY);
        pending = PendingRoles({admin: admin_, keeper: keeper_, eta: eta});
        emit RolesProposed(admin_, keeper_, eta);
    }

    /// @notice Anyone may execute after the delay. A change of admin needs the NEW admin's signature
    ///         (proves it can sign — a typo'd or dead address would freeze the locker).
    function executeRoles(bytes calldata newAdminSig) external {
        PendingRoles memory p = pending;
        if (p.eta == 0) revert NothingPending();
        if (block.timestamp < p.eta) revert TooEarly();
        if (block.timestamp > uint256(p.eta) + ROLE_GRACE) revert ProposalExpired();
        if (p.admin != admin) {
            if (!SignatureChecker.isValidSignatureNow(p.admin, acceptAdminDigest(p.admin), newAdminSig)) revert BadNewAdminSig();
        }
        delete pending;
        _setRoles(p.admin, p.keeper);
    }

    function cancelRoles(uint256 deadline, bytes calldata adminSig) external {
        if (pending.eta == 0) revert NothingPending();
        _checkDeadline(deadline);
        _requireAdmin(cancelRolesDigest(deadline), adminSig);
        delete pending;
        emit RolesCancelled(nonce);
        nonce++;
    }

    // ─── Digests (what the admin signs; exposed for the signing page) ──
    function releaseDigest(uint256 lockId, address to, uint256 deadline) public view returns (bytes32) {
        Lock storage l = locks[lockId];
        return _hashTypedDataV4(keccak256(abi.encode(RELEASE_TYPEHASH, lockId, l.collection, l.tokenId, to, nonce, deadline)));
    }

    function withdrawDigest(uint256 lockId, uint256 deadline) public view returns (bytes32) {
        Lock storage l = locks[lockId];
        return _hashTypedDataV4(keccak256(abi.encode(WITHDRAW_TYPEHASH, lockId, l.collection, l.tokenId, l.depositor, nonce, deadline)));
    }

    function proposeRolesDigest(address admin_, address keeper_, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(PROPOSE_ROLES_TYPEHASH, admin_, keeper_, nonce, deadline)));
    }

    function cancelRolesDigest(uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CANCEL_ROLES_TYPEHASH, nonce, deadline)));
    }

    function acceptAdminDigest(address newAdmin) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ACCEPT_ADMIN_TYPEHASH, newAdmin, nonce)));
    }

    function domainSeparator() external view returns (bytes32) { return _domainSeparatorV4(); }

    /// Accepts ONLY the exact transfer checkIn is performing (this contract as operator, the expected
    /// collection and tokenId). Everything else is refused, so nothing can arrive unregistered via
    /// safeTransferFrom. (Plain transferFrom can't be refused by any contract. Tokens sent that way are NOT
    /// adopted here and can't be recovered — always use checkIn.)
    function onERC721Received(address operator, address, uint256 tokenId, bytes calldata) external view override returns (bytes4) {
        if (!_checkingIn || operator != address(this) || msg.sender != _expectCollection || tokenId != _expectTokenId) {
            revert UnexpectedTransfer();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    // ─── Internal ───────────────────────────────────────────────
    function _live(uint256 lockId) internal view returns (Lock storage l) {
        l = locks[lockId];
        if (l.status != Status.Locked) revert NotLocked();
    }

    function _requireAdmin(bytes32 digest, bytes calldata sig) internal view {
        if (!SignatureChecker.isValidSignatureNow(admin, digest, sig)) revert BadAdminSig();
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert Expired();
        if (deadline > block.timestamp + MAX_DEADLINE) revert DeadlineTooFar();
    }

    function _validateRoles(address admin_, address keeper_) internal pure {
        if (admin_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        if (admin_ == keeper_) revert RolesNotDistinct();
    }

    function _setRoles(address admin_, address keeper_) internal {
        _validateRoles(admin_, keeper_);
        admin = admin_;
        keeper = keeper_;
        emit RolesSet(admin_, keeper_);
    }
}
