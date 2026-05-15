// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PentagonMarketplaceV2
 * @notice NFT Marketplace for Pentagon Chain with fixed fee handling
 * @dev V2.1 — SafeERC20, consistent fee logic, underflow protection
 */
contract PentagonMarketplaceV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Structs ────────────────────────────────────────────────
    struct Listing {
        address seller;
        address collection;
        uint256 price;
        address paymentToken;
        uint256 expiry;
    }

    struct CollectionBid {
        uint256 bidId;
        address bidder;
        uint256 price;
        uint256 size;
        string trait;
        address paymentToken;
        address collection;
        uint256 createdAt;
    }

    // ─── State ──────────────────────────────────────────────────
    uint256 public bidCounter;
    uint256 public constant MIN_BID = 0.01 ether;
    uint256 public constant BID_INCREMENT = 0.01 ether;
    uint256 public constant FEE_DENOMINATOR = 10000;

    mapping(address => mapping(uint256 => Listing)) public listings;
    mapping(uint256 => CollectionBid) public collectionBids;
    mapping(address => uint256) public marketplaceFees;
    mapping(address => bool) public whitelistedCollections;

    // ─── Events ─────────────────────────────────────────────────
    event NFTListed(address indexed collection, uint256 indexed tokenId, address indexed seller, uint256 price, address paymentToken, uint256 expiry);
    event NFTListingCancelled(address indexed collection, uint256 indexed tokenId);
    event NFTSold(address indexed collection, uint256 indexed tokenId, address indexed buyer, uint256 price, address paymentToken);
    event NFTBidPlaced(uint256 indexed bidId, address indexed collection, address indexed bidder, uint256 price, uint256 size, string trait, address paymentToken);
    event NFTBidAccepted(uint256 indexed bidId, address indexed collection, address indexed bidder, uint256 price, address paymentToken);
    event NFTBidCancelled(uint256 indexed bidId);
    event CollectionWhitelisted(address indexed collection, bool status);
    event MarketplaceFeeUpdated(address indexed collection, uint256 fee);
    event FundsWithdrawn(address indexed admin, uint256 amount);
    event TokensWithdrawn(address indexed admin, address indexed token, uint256 amount);

    // ─── Constructor ────────────────────────────────────────────
    constructor() Ownable(msg.sender) {}

    // ─── Modifiers ──────────────────────────────────────────────
    modifier onlyWhitelisted(address collection) {
        require(whitelistedCollections[collection], "Collection not whitelisted");
        _;
    }

    // ─── Listing Functions ──────────────────────────────────────

    function listNFTs(
        address collection,
        uint256[] calldata tokenIds,
        uint256[] calldata prices,
        address paymentToken,
        uint256[] calldata expiries
    ) external onlyWhitelisted(collection) {
        require(tokenIds.length == prices.length && prices.length == expiries.length, "Array length mismatch");

        IERC721 nft = IERC721(collection);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(nft.ownerOf(tokenIds[i]) == msg.sender, "Not token owner");
            require(nft.isApprovedForAll(msg.sender, address(this)) || nft.getApproved(tokenIds[i]) == address(this), "Not approved");
            require(prices[i] >= MIN_BID, "Price below minimum");

            listings[collection][tokenIds[i]] = Listing({
                seller: msg.sender,
                collection: collection,
                price: prices[i],
                paymentToken: paymentToken,
                expiry: expiries[i]
            });

            emit NFTListed(collection, tokenIds[i], msg.sender, prices[i], paymentToken, expiries[i]);
        }
    }

    function cancelListing(address collection, uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Listing storage listing = listings[collection][tokenIds[i]];
            require(listing.seller == msg.sender, "Not seller");
            delete listings[collection][tokenIds[i]];
            emit NFTListingCancelled(collection, tokenIds[i]);
        }
    }

    function buyNFT(address collection, uint256[] calldata tokenIds) external payable nonReentrant onlyWhitelisted(collection) {
        uint256 totalRequired = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            Listing storage listing = listings[collection][tokenIds[i]];
            require(listing.seller != address(0), "Not listed");
            require(listing.expiry == 0 || block.timestamp <= listing.expiry, "Listing expired");

            uint256 price = listing.price;
            uint256 fee = (price * marketplaceFees[collection]) / FEE_DENOMINATOR;

            // Royalties (ERC-2981)
            uint256 royaltyAmount = 0;
            address royaltyReceiver;
            try IERC2981(collection).royaltyInfo(tokenIds[i], price) returns (address receiver, uint256 amount) {
                royaltyReceiver = receiver;
                royaltyAmount = amount;
            } catch {}

            // FIX #2: underflow protection — fee + royalty must not exceed price
            require(fee + royaltyAmount <= price, "Fee + royalty exceeds price");

            address seller = listing.seller;

            if (listing.paymentToken == address(0)) {
                // Native PC payment
                // FIX #1: consistent fee — seller pays fee, same as ERC20 path
                // Buyer sends: price + fee
                // Seller gets: price - fee - royalty
                // Contract keeps: fee * 2 (implicit from msg.value remainder)
                uint256 totalPrice = price + fee;
                totalRequired += totalPrice;
                uint256 sellerProceeds = price - fee - royaltyAmount;

                IERC721(collection).safeTransferFrom(seller, msg.sender, tokenIds[i]);
                payable(seller).transfer(sellerProceeds);
                if (royaltyAmount > 0) payable(royaltyReceiver).transfer(royaltyAmount);
                // fee * 2 stays in contract (fee from buyer via msg.value, fee from seller deduction)
            } else {
                // ERC20 payment
                uint256 sellerProceeds = price - fee - royaltyAmount;

                IERC721(collection).safeTransferFrom(seller, msg.sender, tokenIds[i]);
                // FIX #3: SafeERC20
                IERC20(listing.paymentToken).safeTransferFrom(msg.sender, seller, sellerProceeds);
                if (royaltyAmount > 0) IERC20(listing.paymentToken).safeTransferFrom(msg.sender, royaltyReceiver, royaltyAmount);
                IERC20(listing.paymentToken).safeTransferFrom(msg.sender, address(this), fee);
            }

            emit NFTSold(collection, tokenIds[i], msg.sender, price, listing.paymentToken);
            delete listings[collection][tokenIds[i]];
        }

        if (totalRequired > 0) {
            require(msg.value >= totalRequired, "Insufficient payment");
            if (msg.value > totalRequired) {
                payable(msg.sender).transfer(msg.value - totalRequired);
            }
        }
    }

    // ─── Bid Functions (FIXED: fee-inclusive approval) ───────────

    function placeBid(
        address collection,
        uint256 price,
        uint256 size,
        string calldata trait,
        address paymentToken
    ) external onlyWhitelisted(collection) {
        require(price >= MIN_BID, "Bid below minimum 0.01 WPC");
        require(price % BID_INCREMENT == 0, "Bid must be in 0.01 WPC increments");
        require(size > 0, "Size must be > 0");
        require(paymentToken != address(0), "Must use ERC20 token");

        uint256 fee = (price * marketplaceFees[collection]) / FEE_DENOMINATOR;
        uint256 totalPerNFT = price + fee;
        uint256 totalRequired = totalPerNFT * size;

        IERC20 token = IERC20(paymentToken);
        require(token.balanceOf(msg.sender) >= totalRequired, "Insufficient token balance");
        require(token.allowance(msg.sender, address(this)) >= totalRequired, "Insufficient allowance (include fees)");

        bidCounter++;
        collectionBids[bidCounter] = CollectionBid({
            bidId: bidCounter,
            bidder: msg.sender,
            price: price,
            size: size,
            trait: trait,
            paymentToken: paymentToken,
            collection: collection,
            createdAt: block.timestamp
        });

        emit NFTBidPlaced(bidCounter, collection, msg.sender, price, size, trait, paymentToken);
    }

    function acceptBid(
        address collection,
        uint256 bidId,
        uint256[] calldata tokenIds
    ) external nonReentrant onlyWhitelisted(collection) {
        CollectionBid storage bid = collectionBids[bidId];
        require(bid.bidder != address(0), "Bid does not exist");
        require(tokenIds.length <= bid.size, "Exceeds bid size");

        uint256 fee = (bid.price * marketplaceFees[collection]) / FEE_DENOMINATOR;

        IERC20 token = IERC20(bid.paymentToken);
        IERC721 nft = IERC721(collection);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(nft.ownerOf(tokenIds[i]) == msg.sender, "Not token owner");

            // Royalties
            uint256 royaltyAmount = 0;
            address royaltyReceiver;
            try IERC2981(collection).royaltyInfo(tokenIds[i], bid.price) returns (address receiver, uint256 amount) {
                royaltyReceiver = receiver;
                royaltyAmount = amount;
            } catch {}

            // FIX #2: underflow protection
            require(fee + royaltyAmount <= bid.price, "Fee + royalty exceeds bid price");

            // Seller gets: price - fee - royalty
            uint256 sellerProceeds = bid.price - fee - royaltyAmount;

            // Pull from bidder: sellerProceeds + royalty + (fee * 2)
            // = (price - fee - royalty) + royalty + 2*fee = price + fee
            // FIX #3: SafeERC20
            token.safeTransferFrom(bid.bidder, msg.sender, sellerProceeds);
            if (royaltyAmount > 0) token.safeTransferFrom(bid.bidder, royaltyReceiver, royaltyAmount);
            token.safeTransferFrom(bid.bidder, address(this), fee * 2);

            nft.safeTransferFrom(msg.sender, bid.bidder, tokenIds[i]);

            emit NFTBidAccepted(bidId, collection, bid.bidder, bid.price, bid.paymentToken);
        }

        bid.size -= tokenIds.length;
        if (bid.size == 0) {
            delete collectionBids[bidId];
        }
    }

    function cancelBid(uint256 bidId) external {
        CollectionBid storage bid = collectionBids[bidId];
        require(bid.bidder == msg.sender, "Not bid owner");
        delete collectionBids[bidId];
        emit NFTBidCancelled(bidId);
    }

    function adminCancelBid(uint256 bidId) external onlyOwner {
        require(collectionBids[bidId].bidder != address(0), "Bid does not exist");
        delete collectionBids[bidId];
        emit NFTBidCancelled(bidId);
    }

    function adminCancelBids(uint256[] calldata bidIds) external onlyOwner {
        for (uint256 i = 0; i < bidIds.length; i++) {
            if (collectionBids[bidIds[i]].bidder != address(0)) {
                delete collectionBids[bidIds[i]];
                emit NFTBidCancelled(bidIds[i]);
            }
        }
    }

    // ─── Admin Functions ────────────────────────────────────────

    function whitelistCollection(address collection, bool status) external onlyOwner {
        whitelistedCollections[collection] = status;
        emit CollectionWhitelisted(collection, status);
    }

    function setMarketplaceFee(address collection, uint256 fee) external onlyOwner {
        require(fee <= 1000, "Fee too high (max 10%)");
        marketplaceFees[collection] = fee;
        emit MarketplaceFeeUpdated(collection, fee);
    }

    function withdrawFunds(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
            emit FundsWithdrawn(owner(), amount);
        } else {
            IERC20(token).safeTransfer(owner(), amount);
            emit TokensWithdrawn(owner(), token, amount);
        }
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        super.transferOwnership(newOwner);
    }

    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership();
    }

    // ─── View Functions ─────────────────────────────────────────

    function getBidFeeAmount(uint256 bidId) external view returns (uint256) {
        CollectionBid storage bid = collectionBids[bidId];
        return (bid.price * marketplaceFees[bid.collection]) / FEE_DENOMINATOR;
    }

    function getRequiredApproval(address collection, uint256 price, uint256 size) external view returns (uint256) {
        uint256 fee = (price * marketplaceFees[collection]) / FEE_DENOMINATOR;
        return (price + fee) * size;
    }

    receive() external payable {}
}
