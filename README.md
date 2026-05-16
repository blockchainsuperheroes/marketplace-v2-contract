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

A standalone contract adding three features built around **real auction house mechanics**, not glorified timed listings.

Design philosophy: steal from Christie's and Sotheby's, not OpenSea.

### Contract Architecture (Planned)

```mermaid
flowchart TD
    subgraph "PentagonMarketplaceV2 (LIVE)"
        L[Fixed-Price Listings]
        CB[Collection Bids]
    end

    subgraph "PentagonAuctionHouse (PLANNED)"
        PB[Private Bids — bid on specific NFTs]
        PS[Private Sales — designated buyer, no fee]
        LA[Live Auctions — scheduled, soft-close, bid log]
        RA[Reserve Auctions — hidden reserve, revealed on hit]
        SB[Sealed Bids — blind bidding for high-value pieces]
    end

    L -.-> |"existing"| FEE[Fee System: per-collection bps]
    CB -.-> FEE
    PB --> FEE
    LA --> FEE
    RA --> FEE
    SB --> FEE
    PS -.-> |"NO fee"| FREE[Free Service]
```

Both contracts share whitelisted collections and fee config (new contract can read from V2.1 or duplicate admin setup).

---

### 1. Private Bids (Token-Specific Bids)

Anyone can bid on a **specific NFT they don't own**. Not a collection-wide offer, a direct bid on a particular piece.

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
    else Bid expires
        Note over Contract: After duration passes
        Bidder->>Contract: withdrawExpiredBid(bidId)
        Contract->>Bidder: refund escrowed funds
    else Bidder cancels early
        Bidder->>Contract: cancelPrivateBid(bidId)
        Contract->>Bidder: refund escrowed funds
    end
```

**Rules:**
- Minimum bid: 0.01 PC, increments of 0.01 PC
- Duration-based expiry (bidder sets how long the offer stands)
- Multiple bids per NFT from different bidders allowed
- Funds escrowed on placement (pulled from bidder immediately)
- Marketplace fee applies (same 2.5% structure)
- Bidder can cancel anytime before acceptance. Auto-refund after expiry via `withdrawExpiredBid()`.
- One bid per bidder per NFT (update replaces, prevents spam)

---

### 2. Private Sales (Designated Buyer)

Owner picks exactly who can buy. Peer-to-peer, no middleman fee.

```mermaid
sequenceDiagram
    participant Owner as NFT Owner
    participant Contract as AuctionHouse
    participant Buyer as Designated Buyer

    Owner->>Contract: createPrivateSale(collection, tokenId, price, buyerAddress, paymentToken)
    Note over Contract: One active sale per NFT per owner max
    Contract-->>Owner: PrivateSaleCreated event

    Buyer->>Contract: executePrivateSale(saleId) + payment
    Contract->>Owner: transfer full payment (NO fee deducted)
    Contract->>Buyer: transfer NFT
    Contract-->>Buyer: PrivateSaleExecuted event

    Note over Owner: Owner can cancel anytime before execution
    Owner->>Contract: cancelPrivateSale(saleId)
```

**Rules:**
- **No marketplace fee** (free service, encourages usage)
- Only the designated `buyerAddress` can execute the purchase
- **One active private sale per NFT per owner** (prevents spam/abuse)
- Owner can cancel anytime before buyer executes
- Supports native PC or ERC-20 payment
- No duration (stays active until executed or cancelled)

---

### 3. Live Auctions (Scheduled, Soft-Close, Bid Log)

Real auction mechanics. Scheduled start time, countdown, and a soft-close window that kills sniping.

```mermaid
sequenceDiagram
    participant Owner as NFT Owner
    participant Contract as AuctionHouse
    participant B1 as Bidder 1
    participant B2 as Bidder 2
    participant Anyone

    Owner->>Contract: createAuction(collection, tokenId, startPrice, duration, startTime, paymentToken)
    Note over Contract: NFT escrowed. Auction starts at startTime.
    Contract-->>Owner: AuctionCreated event

    Note over Contract: ⏰ startTime reached — auction is LIVE

    B1->>Contract: bid(auctionId) + funds
    Note over Contract: Escrow bid. Must beat startPrice.
    Contract-->>B1: BidPlaced(auctionId, bidder, amount, timestamp)

    B2->>Contract: bid(auctionId) + higher funds
    Contract->>B1: refund previous bid immediately
    Contract-->>B2: BidPlaced event

    B2->>Contract: increaseBid(auctionId) + additional funds
    Note over Contract: Top up existing bid without losing position
    Contract-->>B2: BidIncreased event

    Note over Contract: 🔥 SOFT-CLOSE: bid in last 10 min → extend 10 min
    B1->>Contract: bid(auctionId) + even higher funds
    Note over Contract: endTime += 10 minutes (anti-sniping)
    Contract->>B2: refund previous bid
    Contract-->>B1: BidPlaced + AuctionExtended events

    Note over Contract: ⏰ endTime reached, no more bids in window

    Anyone->>Contract: settleAuction(auctionId)
    Contract->>Owner: transfer(winningBid - fee - royalty)
    Contract->>B1: transfer NFT to winner
    Contract-->>Anyone: AuctionSettled event
```

**Rules:**
- **Scheduled start:** Owner sets a future `startTime`. No bids accepted before it.
- **Soft-close (anti-sniping):** Any bid placed within 10 minutes of `endTime` extends the auction by 10 minutes. Repeats indefinitely until 10 minutes pass with no bids.
- **Live bid log:** Every bid emits `BidPlaced(auctionId, bidder, amount, timestamp)` for frontend to render a live feed.
- **Bid increments:** Must exceed current highest by at least 0.01 PC.
- **Increase bid:** Current highest bidder can top up their bid (keeps position).
- **Outbid refund:** Previous highest bidder gets an immediate refund when outbid.
- **Settlement:** Anyone can call `settleAuction()` after `endTime`. Permissionless finalization.
- **Escrow model:** NFT held by contract from creation. Winning bid funds held until settlement.
- **Fee + royalties** charged on successful settlement.
- **No bids?** Owner can reclaim NFT after `endTime` via `reclaimUnsold(auctionId)`.

---

### 4. Reserve Auctions (Hidden Reserve, Revealed on Hit)

Same mechanics as live auctions, plus a hidden reserve price. Bidders don't know the floor until someone hits it.

```mermaid
sequenceDiagram
    participant Owner as NFT Owner
    participant Contract as AuctionHouse
    participant B1 as Bidder 1
    participant B2 as Bidder 2

    Owner->>Contract: createReserveAuction(collection, tokenId, startPrice, reservePrice, duration, startTime, paymentToken)
    Note over Contract: reservePrice stored as hash (hidden on-chain)
    Contract-->>Owner: ReserveAuctionCreated event

    B1->>Contract: bid(auctionId) + funds below reserve
    Note over Contract: Bid accepted but reserve NOT met
    Contract-->>B1: BidPlaced (reserveMet: false)

    B2->>Contract: bid(auctionId) + funds >= reserve
    Contract->>B1: refund
    Note over Contract: 🎯 RESERVE MET — revealed to all bidders
    Contract-->>B2: BidPlaced (reserveMet: true) + ReserveRevealed event

    Note over Contract: From here, normal soft-close auction rules apply

    alt Reserve met → settleAuction
        Contract->>Owner: proceeds
        Contract->>B2: NFT
    else Reserve NOT met at end
        Owner->>Contract: cancelReserveAuction(auctionId)
        Contract->>Owner: return NFT
        Contract->>B1: refund highest bid
    end
```

**Rules:**
- **Hidden reserve:** Stored as `keccak256(reservePrice, salt)` on-chain. Not visible until met.
- **Reserve reveal:** When a bid meets or exceeds reserve, contract emits `ReserveRevealed(auctionId, reservePrice)`. From that point it's a normal auction.
- **Reserve not met:** Owner can cancel after `endTime` and reclaim NFT + all bids refunded.
- **Soft-close still applies** once reserve is met.
- All other live auction rules carry over.

---

### 5. Sealed Bids (Blind Auction for High-Value Pieces)

Commit-reveal pattern. Nobody sees anyone else's bid until the reveal phase.

```mermaid
sequenceDiagram
    participant Owner as NFT Owner
    participant Contract as AuctionHouse
    participant B1 as Bidder 1
    participant B2 as Bidder 2

    Owner->>Contract: createSealedAuction(collection, tokenId, minBid, bidPhaseEnd, revealPhaseEnd, paymentToken)
    Note over Contract: NFT escrowed
    Contract-->>Owner: SealedAuctionCreated event

    rect rgb(240, 240, 255)
        Note over Contract: 📦 BID PHASE (commit)
        B1->>Contract: commitBid(auctionId, hash) + escrow deposit
        Note over Contract: hash = keccak256(amount, salt)
        B2->>Contract: commitBid(auctionId, hash) + escrow deposit
    end

    rect rgb(255, 240, 240)
        Note over Contract: 🔓 REVEAL PHASE
        B1->>Contract: revealBid(auctionId, amount, salt)
        Note over Contract: Verify hash matches. Refund excess deposit.
        B2->>Contract: revealBid(auctionId, amount, salt)
        Note over Contract: If amount > deposit, bid is invalid (disqualified)
    end

    Note over Contract: ⏰ revealPhaseEnd reached

    Contract->>Contract: Highest valid revealed bid wins
    Contract->>Owner: transfer(winningBid - fee - royalty)
    Contract->>B1: transfer NFT to winner
    Contract->>B2: refund deposit
    Contract-->>Owner: SealedAuctionSettled event
```

**Rules:**
- **Two phases:** Commit (bid phase) then Reveal.
- **Commit:** Bidder submits `keccak256(amount, salt)` + deposits at least `minBid` as escrow. Actual bid amount is hidden.
- **Reveal:** Bidder reveals `amount` and `salt`. Contract verifies hash. If `amount > deposit`, bid is disqualified (can't bid more than you escrowed).
- **Unrevealed bids:** Deposit is forfeited after reveal phase (incentivizes revealing).
- **Winner:** Highest valid revealed bid. Ties broken by earlier commit timestamp.
- **Settlement:** Automatic after reveal phase ends. Anyone can call `settleSealedAuction()`.
- **Fee + royalties** on winning amount.
- **Use case:** High-value 1/1s, flagship drops, situations where visible bidding creates psychological pressure or collusion risk.

---

## Repository

- **Gitea (primary):** http://10.0.0.124:3000/nftprof/marketplace-v2-contract
- **GitHub:** https://github.com/blockchainsuperheroes/marketplace-v2-contract

## License

MIT
