# Pentagon Marketplace Contracts

NFT Marketplace smart contracts for **Pentagon Chain** (Chain ID: 3344).

## Contract Summary

| Contract | Address | Status |
|----------|---------|--------|
| **PentagonMarketplaceV2 (V2.1)** | `0xecC0ba6e383EE0C2Af89dF54cdC6Db743421a76A` | ✅ LIVE |
| PentagonMarketplaceV2 (V2) | `0xCF4582883e73c5bd00F6F11A8929428ACAEDb7aF` | ❌ DEPRECATED |
| PentagonMarketplaceV1 | `0x704C82eB1f2a6f700743Eaa7c5c7678263B80500` | ❌ DEPRECATED |

**Chain:** Pentagon Chain (3344)
**RPC:** `https://rpc.pentagon.games`
**Deployer:** `0xE6d7d2EB858BC78f0c7EdD2c00B3b24C02ca5177`

---

## Architecture

**1 contract** handles everything: listings, purchases, and collection bids.

```
PentagonMarketplaceV2 (Ownable, ReentrancyGuard)
├── Listings       — sellers list NFTs at fixed prices, buyers purchase
├── Collection Bids — bidders offer on any NFT in a collection, sellers accept
├── Fee System     — per-collection basis points, ERC-2981 royalties
└── Admin          — owner + moderator roles, whitelisting, fee config
```

**Dependencies:** OpenZeppelin v5 (Ownable, ReentrancyGuard, SafeERC20, IERC2981, IERC721)

### Roles

| Role | Permissions |
|------|-------------|
| **Owner** | All moderator permissions + `setMarketplaceFee`, `withdrawFunds`, `addModerator`, `removeModerator`, `transferOwnership` |
| **Moderator** | `whitelistCollection`, `adminCancelBid`, `adminCancelBids` |

---

## Flow Diagrams

### Listing Flow (List, Buy, Cancel)

```mermaid
sequenceDiagram
    participant Seller
    participant Marketplace
    participant Buyer
    participant NFT as ERC-721

    Note over Seller: Must approve Marketplace for NFT
    Seller->>Marketplace: listNFTs(collection, tokenIds, prices, paymentToken, expiries)
    Marketplace->>NFT: verify ownerOf + approval
    Marketplace-->>Seller: NFTListed event

    Buyer->>Marketplace: buyNFT(collection, tokenIds) + msg.value or ERC20 approval
    Marketplace->>NFT: safeTransferFrom(seller → buyer)
    Marketplace->>Seller: transfer(price - fee - royalty)
    Marketplace->>Marketplace: keep fee (2x: buyer fee + seller deduction)
    Marketplace-->>Buyer: NFTSold event

    Note over Seller: Can cancel anytime before sale
    Seller->>Marketplace: cancelListing(collection, tokenIds)
    Marketplace-->>Seller: NFTListingCancelled event
```

### Collection Bid Flow (Place, Accept, Cancel)

```mermaid
sequenceDiagram
    participant Bidder
    participant Marketplace
    participant Seller
    participant NFT as ERC-721
    participant Token as ERC-20

    Note over Bidder: Must approve Marketplace for (price + fee) * size
    Bidder->>Marketplace: placeBid(collection, price, size, trait, paymentToken)
    Marketplace->>Token: verify balance + allowance >= (price + fee) * size
    Marketplace-->>Bidder: NFTBidPlaced event

    Seller->>Marketplace: acceptBid(collection, bidId, tokenIds)
    Marketplace->>Token: safeTransferFrom(bidder → seller, sellerProceeds)
    Marketplace->>Token: safeTransferFrom(bidder → royaltyReceiver, royalty)
    Marketplace->>Token: safeTransferFrom(bidder → contract, fee * 2)
    Marketplace->>NFT: safeTransferFrom(seller → bidder)
    Marketplace-->>Seller: NFTBidAccepted event

    Note over Bidder: Can cancel own bids anytime
    Bidder->>Marketplace: cancelBid(bidId)
    Marketplace-->>Bidder: NFTBidCancelled event
```

### Fee Flow

```mermaid
flowchart LR
    subgraph "Direct Purchase (Listing)"
        B[Buyer pays: price + fee] --> S1[Seller gets: price - fee - royalty]
        B --> R1[Royalty Receiver gets: royalty]
        B --> C1[Contract keeps: 2x fee]
    end

    subgraph "Collection Bid Accepted"
        BD[Bidder pays: price + fee] --> S2[Seller gets: price - fee - royalty]
        BD --> R2[Royalty Receiver gets: royalty]
        BD --> C2[Contract keeps: 2x fee]
    end
```

### Admin Flow

```mermaid
flowchart TD
    Owner --> |addModerator / removeModerator| Moderators
    Owner --> |setMarketplaceFee| Fees[Per-Collection Fees]
    Owner --> |withdrawFunds| Treasury[Contract Balance]
    Owner --> |transferOwnership| NewOwner
    Moderators --> |whitelistCollection| Collections
    Moderators --> |adminCancelBid / adminCancelBids| Bids
```

---

## Function Reference

### Constants

| Name | Value | Description |
|------|-------|-------------|
| `MIN_BID` | 0.01 ether | Minimum listing price or bid amount |
| `BID_INCREMENT` | 0.01 ether | Bids must be multiples of this |
| `FEE_DENOMINATOR` | 10000 | Basis points denominator (100% = 10000) |

### Listing Functions

#### `listNFTs(collection, tokenIds[], prices[], paymentToken, expiries[])`
List one or more NFTs for sale. Caller must own the tokens and have approved the marketplace. Collection must be whitelisted. Prices must be >= MIN_BID. Set `expiry = 0` for no expiration. Use `paymentToken = address(0)` for native PC payment, or an ERC-20 address.

#### `cancelListing(collection, tokenIds[])`
Cancel one or more of your own listings. Only the original seller can cancel.

#### `buyNFT(collection, tokenIds[])`
Purchase one or more listed NFTs. For native PC: send `msg.value >= sum(price + fee)`. For ERC-20: approve the marketplace for the total amount first. Handles ERC-2981 royalties automatically. Excess native PC is refunded.

### Collection Bid Functions

#### `placeBid(collection, price, size, trait, paymentToken)`
Place a bid on any NFT in a whitelisted collection. `size` = how many NFTs you want at that price. `trait` is a string filter (off-chain matching). Must use ERC-20 (`paymentToken != address(0)`). Bidder must have balance and allowance for `(price + fee) * size`.

#### `acceptBid(collection, bidId, tokenIds[])`
Accept a collection bid by providing specific token IDs. Caller must own the tokens. Can partially fill (accept fewer than `size`). Remaining `size` stays open.

#### `cancelBid(bidId)`
Cancel your own bid. Only the original bidder can cancel.

#### `adminCancelBid(bidId)` / `adminCancelBids(bidIds[])`
Moderator/owner can cancel any bid(s). Used for spam cleanup or collection de-whitelisting.

### Admin Functions

#### `addModerator(address)` / `removeModerator(address)` (Owner only)
Grant or revoke moderator role.

#### `whitelistCollection(collection, status)` (Moderator+)
Enable or disable a collection for trading.

#### `setMarketplaceFee(collection, fee)` (Owner only)
Set fee in basis points for a collection. Max 1000 (10%).

#### `withdrawFunds(token, amount)` (Owner only)
Withdraw accumulated fees. `token = address(0)` for native PC, otherwise ERC-20 address.

### View Functions

#### `getBidFeeAmount(bidId)` → `uint256`
Returns the fee amount for a specific bid.

#### `getRequiredApproval(collection, price, size)` → `uint256`
Returns total ERC-20 approval needed: `(price + fee) * size`.

---

## Fee Structure

- **Per-collection**, set in basis points (1 bp = 0.01%)
- **Current rate:** 250 bps (2.5%) on all whitelisted collections
- **Max allowed:** 1000 bps (10%)
- **Double fee model:** Contract collects fee from BOTH sides
  - Buyer/bidder pays: `price + fee`
  - Seller receives: `price - fee - royalty`
  - Contract keeps: `fee * 2`
- **ERC-2981 royalties** deducted from seller proceeds automatically

---

## Whitelisted Collections

| Collection | Address | Fee |
|------------|---------|-----|
| Setsuko | `0xcDAD57bFc48E8373280C6dc3039C5169353B6879` | 2.5% |
| Jewelry | `0xc05b96b89Ce46c306223E3f4c413891d17E1De70` | 2.5% |
| Gunnies PFP | `0x7a8a3236e3783E7cC33b97729378e31Cf14d3Ebc` | 2.5% |
| EF Genesis | `0x8F83c6122Dd4d275B53a7846B3D3dB29Cca1e698` | 2.5% |
| Rugpull | `0xD77f88ef51b2589D132D6eb61068079F61Dfe4A3` | 2.5% |

---

## Security (V2.1 Audit Fixes)

| Fix | Description |
|-----|-------------|
| **SafeERC20** | All ERC-20 transfers use `safeTransferFrom` / `safeTransfer` |
| **Underflow protection** | `require(fee + royaltyAmount <= price)` before subtraction |
| **Consistent fee logic** | Native PC and ERC-20 paths charge fees identically |
| **ReentrancyGuard** | On `buyNFT` and `acceptBid` (all payment functions) |
| **Moderator role** | Separates collection management from owner-level access |

---

## Deployment

Built with [Foundry](https://book.getfoundry.sh/).

```bash
# Build
forge build

# Test
forge test

# Deploy
forge script script/Deploy.s.sol:DeployMarketplaceV2 \
  --rpc-url pentagon \
  --private-key $PRIVATE_KEY \
  --broadcast
```

**Foundry config:** `via_ir = true`, optimizer 200 runs, solc 0.8.20

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| V1 | 2024 | Initial marketplace. DEPRECATED, 224 stale bids hidden, collections disabled. |
| V2 | May 2025 | Rewrite with ERC-20 support, collection bids, royalties. No funds ever flowed. |
| V2.1 | May 2025 | Audit fixes: SafeERC20, underflow protection, consistent fees, moderator role. **LIVE** |

---

## Planned: PentagonAuctionHouse Contract

A new standalone contract to add three features currently missing from the marketplace:

### 1. Private Bids (Token-Specific Bids)

Bid on a **specific NFT** (by collection + tokenId) rather than any NFT in a collection.

```mermaid
sequenceDiagram
    participant Bidder
    participant Contract as AuctionHouse
    participant Owner as NFT Owner

    Bidder->>Contract: placePrivateBid(collection, tokenId, price, duration, paymentToken)
    Note over Contract: Escrow: pull price + fee from bidder
    Contract-->>Bidder: PrivateBidPlaced event

    alt Owner accepts
        Owner->>Contract: acceptPrivateBid(bidId)
        Contract->>Owner: transfer(price - fee - royalty)
        Contract->>Bidder: transfer NFT
        Contract-->>Owner: PrivateBidAccepted event
    else Bid expires or bidder cancels
        Bidder->>Contract: cancelPrivateBid(bidId)
        Contract->>Bidder: refund escrowed funds
    end
```

**Rules:**
- Minimum bid: 0.01 PC, increments of 0.01 PC
- Duration-based expiry (bidder sets)
- Multiple bids per NFT from different bidders allowed
- Funds escrowed on bid placement (pulled from bidder)
- Marketplace fee applies (same 2.5% structure)
- Bidder can cancel anytime (if not accepted). Auto-refund on expiry.

### 2. Private Sales

NFT owner creates a sale that **only one specific address** can buy.

```mermaid
sequenceDiagram
    participant Owner as NFT Owner
    participant Contract as AuctionHouse
    participant Buyer as Designated Buyer

    Owner->>Contract: createPrivateSale(collection, tokenId, price, buyer, paymentToken)
    Note over Contract: One active private sale per NFT per owner
    Contract-->>Owner: PrivateSaleCreated event

    Buyer->>Contract: executePrivateSale(saleId) + payment
    Contract->>Owner: transfer payment (NO fee)
    Contract->>Buyer: transfer NFT
    Contract-->>Buyer: PrivateSaleExecuted event

    Note over Owner: Can cancel anytime
    Owner->>Contract: cancelPrivateSale(saleId)
```

**Rules:**
- **No marketplace fee** (free service, peer-to-peer)
- Only the designated `buyer` address can execute
- One active private sale per NFT per owner (prevents spam/abuse)
- Owner can cancel anytime
- Supports native PC or ERC-20 payment

### 3. Auctions (English Auction, OpenSea-style)

Owner starts a timed auction. Highest bidder wins.

```mermaid
sequenceDiagram
    participant Owner as NFT Owner
    participant Contract as AuctionHouse
    participant B1 as Bidder 1
    participant B2 as Bidder 2

    Owner->>Contract: createAuction(collection, tokenId, startPrice, reservePrice, duration, paymentToken)
    Note over Contract: NFT transferred to contract (escrow)
    Contract-->>Owner: AuctionCreated event

    B1->>Contract: placeBid(auctionId) + funds
    Note over Contract: Escrow bid amount
    Contract-->>B1: AuctionBidPlaced event

    B2->>Contract: placeBid(auctionId) + higher funds
    Contract->>B1: refund previous bid
    Note over Contract: If < 10 min left, extend by 10 min
    Contract-->>B2: AuctionBidPlaced event

    B2->>Contract: increaseBid(auctionId) + additional funds
    Note over Contract: Add to existing bid
    Contract-->>B2: AuctionBidIncreased event

    Note over Contract: Auction ends (duration reached)

    alt Reserve met
        Anyone->>Contract: settleAuction(auctionId)
        Contract->>Owner: transfer(winningBid - fee - royalty)
        Contract->>B2: transfer NFT
        Contract-->>B2: AuctionSettled event
    else Reserve NOT met
        Owner->>Contract: cancelAuction(auctionId)
        Contract->>Owner: return NFT
        Contract->>B2: refund bid
    end
```

**Rules:**
- **Anti-sniping:** Bids in the last 10 minutes extend the auction by 10 minutes (OpenSea model)
- **Reserve price:** Optional. If set and not met, owner can cancel and reclaim NFT
- **No reserve:** Sells to highest bidder regardless of final price
- **Bid increments:** Each new bid must exceed current highest by at least 0.01 PC
- **Increase bid:** Existing highest bidder can add to their bid without losing position
- **Settlement:** Anyone can call `settleAuction()` after end time. Finalizes transfer + payment.
- **Escrow model:** NFT held by contract during auction, bids escrowed on placement
- **Fee charged** on successful settlement (same basis-point structure)
- **ERC-2981 royalties** honored on settlement

### Contract Architecture (Planned)

```mermaid
flowchart TD
    subgraph "PentagonMarketplaceV2 (LIVE)"
        L[Fixed-Price Listings]
        CB[Collection Bids]
    end

    subgraph "PentagonAuctionHouse (PLANNED)"
        PB[Private Bids — bid on specific NFT]
        PS[Private Sales — designated buyer only]
        AU[Auctions — timed, highest bidder wins]
    end

    L -.-> |"existing"| FEE[Fee System: per-collection bps]
    CB -.-> FEE
    PB --> FEE
    AU --> FEE
    PS -.-> |"NO fee"| FREE[Free Service]
```

Both contracts share the same whitelisted collections and fee configuration (or the new contract reads from V2.1, or duplicates the admin setup).

---

## Repository

- **Gitea (primary):** http://10.0.0.124:3000/nftprof/marketplace-v2-contract
- **GitHub:** https://github.com/blockchainsuperheroes/marketplace-v2-contract

## License

MIT
