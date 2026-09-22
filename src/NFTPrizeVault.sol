// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";

/// @title NFTPrizeVault — Ethereum-side escrow for Pentagon Vault Drops prizes
/// @notice The project checks a prize NFT into this vault for a given Pentagon drop. It leaves ONLY
///         through one of two fixed paths:
///           • release()   → to the drop's winner, and ONLY with a 2-of-2 EIP-712 attestation from
///                           two independent signers (keeper + verifier, separate KMS keys, separate
///                           Pentagon RPCs) that BOTH observed the same DropSettled outcome, AND the
///                           owner submitting that attestation from the hardware wallet (3rd key).
///           • invalidate()/reclaim() → back to the owner. Permanent for that drop (dead[dropId]).
///         The vault never outputs ETH, never executes arbitrary calldata, and has no PC↔ETH rate.
///
///         Trust model (deliberate): a valid attestation is NECESSARY but not SUFFICIENT. The owner
///         must review (settle tx, bid history, winner, live ownerOf) and submit. Availability is
///         traded for safety — do NOT automate the owner submit. If Pentagon chain state is ever
///         compromised, the owner simply does not submit, calls invalidate(), and refunds PC-side.
contract NFTPrizeVault is Ownable2Step, Pausable, ReentrancyGuard, EIP712, IERC721Receiver {
    // ─── Types ──────────────────────────────────────────────────
    struct Prize {
        address collection;
        uint256 tokenId;
        bool deposited;
        bool released;
        bool dead; // set by invalidate()/reclaim(); permanent
    }

    // ─── Constants ──────────────────────────────────────────────
    bytes32 public constant RELEASE_TYPEHASH = keccak256(
        "Release(uint256 dropId,address collection,uint256 tokenId,address winner,uint256 srcChainId,address srcContract,bytes32 srcSettleTx,uint256 deadline)"
    );
    /// @dev Attestations are consumed by a human with a hardware wallet, not a bot — 48h keeps a
    ///      missed window from forcing needless re-attestation. Also bounds future-dated sigs.
    uint256 public constant MAX_DEADLINE = 48 hours;

    // ─── Immutables (the ONE Pentagon drops contract this vault serves) ──
    uint256 public immutable SRC_CHAIN_ID; // 3344
    address public immutable SRC_CONTRACT; // PentagonVaultDrops on Pentagon

    // ─── State ──────────────────────────────────────────────────
    address public keeper;
    address public verifier;
    mapping(uint256 => Prize) public prizes; // dropId → prize
    /// @dev (collection, tokenId) → dropId+1 while held for a live drop; 0 = not bound.
    mapping(address => mapping(uint256 => uint256)) private boundTo;

    // ─── Events ─────────────────────────────────────────────────
    event SignersUpdated(address keeper, address verifier);
    event Deposited(uint256 indexed dropId, address indexed collection, uint256 indexed tokenId);
    event Released(uint256 indexed dropId, address indexed collection, uint256 indexed tokenId, address winner, bytes32 srcSettleTx);
    event Invalidated(uint256 indexed dropId, address indexed collection, uint256 indexed tokenId, bool reclaim);
    event Rescued(address indexed collection, uint256 indexed tokenId, address to);

    // ─── Errors ─────────────────────────────────────────────────
    error ZeroAddress();
    error SameSigner();
    error AlreadyUsed();
    error NotDeposited();
    error AlreadyReleased();
    error DropDead();
    error BadWinner();
    error Expired();
    error DeadlineTooFar();
    error WrongSource();
    error BadKeeperSig();
    error BadVerifierSig();
    error NotHeld();
    error Bound();

    constructor(address _owner, address _keeper, address _verifier, uint256 _srcChainId, address _srcContract)
        Ownable(_owner)
        EIP712("PentagonVaultDrops", "1")
    {
        if (_srcContract == address(0)) revert ZeroAddress();
        SRC_CHAIN_ID = _srcChainId;
        SRC_CONTRACT = _srcContract;
        _setSigners(_keeper, _verifier);
    }

    // ─── Signers (KMS rotation) ─────────────────────────────────
    function setSigners(address _keeper, address _verifier) external onlyOwner {
        _setSigners(_keeper, _verifier);
    }

    function _setSigners(address _keeper, address _verifier) internal {
        if (_keeper == address(0) || _verifier == address(0)) revert ZeroAddress();
        if (_keeper == _verifier) revert SameSigner();
        keeper = _keeper;
        verifier = _verifier;
        emit SignersUpdated(_keeper, _verifier);
    }

    // ─── Deposit (owner checks the prize in) ────────────────────
    /// @notice Pulls `tokenId` from the owner into the vault and binds it to `dropId`. One NFT per
    ///         drop, one drop per NFT. Owner must have approved the vault first.
    function deposit(uint256 dropId, address collection, uint256 tokenId) external onlyOwner nonReentrant {
        Prize storage p = prizes[dropId];
        if (p.deposited) revert AlreadyUsed();
        if (collection == address(0)) revert ZeroAddress();
        if (boundTo[collection][tokenId] != 0) revert Bound();

        p.collection = collection;
        p.tokenId = tokenId;
        p.deposited = true;
        boundTo[collection][tokenId] = dropId + 1;

        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);
        if (IERC721(collection).ownerOf(tokenId) != address(this)) revert NotHeld();
        emit Deposited(dropId, collection, tokenId);
    }

    // ─── Release (owner-submitted, 2-of-2 attested) ─────────────
    /// @param srcSettleTx  Pentagon tx hash of DropSettled — informational binding, emitted for audit.
    /// @param deadline     Attestation expiry; must be ≤ now + MAX_DEADLINE.
    function release(
        uint256 dropId,
        address winner,
        bytes32 srcSettleTx,
        uint256 deadline,
        bytes calldata sigKeeper,
        bytes calldata sigVerifier
    ) external onlyOwner whenNotPaused nonReentrant {
        Prize storage p = prizes[dropId];
        if (!p.deposited) revert NotDeposited();
        if (p.released) revert AlreadyReleased();
        if (p.dead) revert DropDead();
        if (winner == address(0) || winner == address(this)) revert BadWinner();
        if (block.timestamp > deadline) revert Expired();
        if (deadline > block.timestamp + MAX_DEADLINE) revert DeadlineTooFar();

        bytes32 digest = releaseDigest(dropId, p.collection, p.tokenId, winner, srcSettleTx, deadline);
        // ECDSA.recover reverts on malformed / high-s / zero recovery — no silent address(0).
        if (ECDSA.recover(digest, sigKeeper) != keeper) revert BadKeeperSig();
        if (ECDSA.recover(digest, sigVerifier) != verifier) revert BadVerifierSig();

        p.released = true;
        boundTo[p.collection][p.tokenId] = 0;
        IERC721(p.collection).safeTransferFrom(address(this), winner, p.tokenId);
        emit Released(dropId, p.collection, p.tokenId, winner, srcSettleTx);
    }

    /// @notice The exact digest both signers must sign. srcChainId/srcContract are pinned to this
    ///         vault's immutables so an attestation for another deployment can never be replayed here.
    function releaseDigest(
        uint256 dropId,
        address collection,
        uint256 tokenId,
        address winner,
        bytes32 srcSettleTx,
        uint256 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    RELEASE_TYPEHASH, dropId, collection, tokenId, winner, SRC_CHAIN_ID, SRC_CONTRACT, srcSettleTx, deadline
                )
            )
        );
    }

    // ─── Invalidate / Reclaim (owner takes the prize back; permanent) ──
    /// @notice Drop compromised, or no valid winner. Prize returns to owner; drop is dead forever.
    function invalidate(uint256 dropId) external onlyOwner nonReentrant {
        _return(dropId, false);
    }

    /// @notice Drop ended without a deliverable winner (no bids / winner refunded PC-side).
    function reclaim(uint256 dropId) external onlyOwner nonReentrant {
        _return(dropId, true);
    }

    function _return(uint256 dropId, bool isReclaim) internal {
        Prize storage p = prizes[dropId];
        if (!p.deposited) revert NotDeposited();
        if (p.released) revert AlreadyReleased();
        if (p.dead) revert DropDead();
        p.dead = true;
        boundTo[p.collection][p.tokenId] = 0;
        IERC721(p.collection).safeTransferFrom(address(this), owner(), p.tokenId);
        emit Invalidated(dropId, p.collection, p.tokenId, isReclaim);
    }

    // ─── Rescue (only tokens NOT bound to a live drop, e.g. stray sends) ──
    function rescueUnbound(address collection, uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (boundTo[collection][tokenId] != 0) revert Bound();
        IERC721(collection).safeTransferFrom(address(this), to, tokenId);
        emit Rescued(collection, tokenId, to);
    }

    // ─── Pause (stops release only; invalidate/reclaim stay open) ──
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── Views ──────────────────────────────────────────────────
    function isReleasable(uint256 dropId) external view returns (bool) {
        Prize storage p = prizes[dropId];
        return p.deposited && !p.released && !p.dead && !paused()
            && IERC721(p.collection).ownerOf(p.tokenId) == address(this);
    }

    function domainSeparator() external view returns (bytes32) { return _domainSeparatorV4(); }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
