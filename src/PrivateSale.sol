// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PentagonPrivateSale
 * @notice No-fee, designated-buyer private sales (v2-dev Feature 2) for PFP Vault v1.3.
 * @dev Peer-to-peer OTC: a seller offers a specific tokenId to ONE buyer at a fixed price.
 *      NO marketplace fee and NO royalty deduction — the seller receives the full price (this is
 *      the "private sales facility (no fees)" pillar). No escrow: the seller keeps custody and
 *      must approve this contract for the token; the transfer happens atomically on execute.
 *
 *      ⚠ UNAUDITED. Run `forge test` + audit before any deployment. Handles funds + NFT transfer.
 */
contract PentagonPrivateSale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Sale {
        address seller;
        address collection;
        uint256 tokenId;
        uint256 price;
        address buyer; // the ONLY address allowed to execute
        address paymentToken; // address(0) = native
        bool active;
    }

    uint256 public saleCounter;
    mapping(uint256 => Sale) public sales;

    event PrivateSaleCreated(
        uint256 indexed saleId,
        address indexed seller,
        address indexed collection,
        uint256 tokenId,
        uint256 price,
        address buyer,
        address paymentToken
    );
    event PrivateSaleExecuted(uint256 indexed saleId, address indexed buyer, uint256 price);
    event PrivateSaleCancelled(uint256 indexed saleId);

    /// @notice Seller offers `tokenId` to `buyer` at `price`. Approve this contract for the token first.
    function createPrivateSale(
        address collection,
        uint256 tokenId,
        uint256 price,
        address buyer,
        address paymentToken
    ) external returns (uint256 saleId) {
        require(buyer != address(0) && buyer != msg.sender, "Bad buyer");
        require(price > 0, "Price 0");
        require(IERC721(collection).ownerOf(tokenId) == msg.sender, "Not token owner");

        saleId = ++saleCounter;
        sales[saleId] = Sale({
            seller: msg.sender,
            collection: collection,
            tokenId: tokenId,
            price: price,
            buyer: buyer,
            paymentToken: paymentToken,
            active: true
        });
        emit PrivateSaleCreated(saleId, msg.sender, collection, tokenId, price, buyer, paymentToken);
    }

    /// @notice Only the designated buyer can execute. Seller receives the full price (no fee).
    function executePrivateSale(uint256 saleId) external payable nonReentrant {
        Sale storage s = sales[saleId];
        require(s.active, "Not active");
        require(msg.sender == s.buyer, "Not designated buyer");
        require(IERC721(s.collection).ownerOf(s.tokenId) == s.seller, "Seller no longer owns");
        s.active = false;

        if (s.paymentToken == address(0)) {
            require(msg.value == s.price, "Wrong native value");
            (bool ok, ) = payable(s.seller).call{value: s.price}("");
            require(ok, "Payment failed");
        } else {
            require(msg.value == 0, "Native not accepted");
            IERC20(s.paymentToken).safeTransferFrom(msg.sender, s.seller, s.price);
        }

        IERC721(s.collection).safeTransferFrom(s.seller, s.buyer, s.tokenId);
        emit PrivateSaleExecuted(saleId, s.buyer, s.price);
    }

    /// @notice Seller cancels an open sale.
    function cancelPrivateSale(uint256 saleId) external {
        Sale storage s = sales[saleId];
        require(s.active, "Not active");
        require(msg.sender == s.seller, "Not seller");
        s.active = false;
        emit PrivateSaleCancelled(saleId);
    }
}
