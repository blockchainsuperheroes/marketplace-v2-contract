# Floor bids from the fee fund (spec, approved by nftprof 2026-11-02)

The fee fund (`floorFundOf[collection]`) is spent as standing bids just under the real floor. NFTs it buys go to the
Redeem store and are never relisted. We are a patient buyer, not a market maker.

## Reference floor

The lower of:
1. **Recent sales:** the low end of the last 7 days of completed sales, after nft-data's wash and outlier filter.
2. **Cheapest live listing elsewhere:** read by the bot only. It is never shown on our site, and order books are never aggregated.

Taking the lower of the two means a pumped floor can't pull the bid up.

## Bid price

| Collection activity | Bid below the reference |
|---|---|
| Liquid (several sales a day) | 5–8% |
| Thin (a few sales a week) | 10–15% |
| Very thin (under ~1 sale a week) | no bid; buy by hand if a good one appears |

Launch setting: **10% below the reference** for every collection, tuned per tier once the sales data is live.

## Guardrails

- **Expiry:** each bid lasts 48h. MarketplaceV3 offers can't be re-priced, so the bot cancels, which refunds the full escrow, and places a new bid.
- **Re-price:** only when the reference moves more than 5%, or once a day, to limit gas.
- **Drop watchdog:** if the reference falls 7% or more, cancel at once and re-place lower.
- **Size:** quantity 1 per bid, plus a daily spend cap per collection. A crash can cost at most one NFT.
- **Which tokens may fill:** the offer's `tokensRoot` lists only tokens that pass nft-data's art check and aren't flagged. A root of 0 would let the worst token in the collection fill it.
- **Price flag:** skip the collection when its floor is more than 1.2× the 7-day average sale. The admin dashboard already shows this flag.

## Wallets and keys

- **Bidding wallet:** a dedicated hot wallet whose key is held in AWS KMS (from the AWS Admin session), separate from the bridge and Redeem keys. It places and cancels bids within the limits above.
- **Refills:** 0xB2e3 refills it from the fee fund (`withdrawFloorFund(collection, biddingWallet, amount)`), a small amount at a time.
- **Bought NFTs:** they move to the Redeem inventory, labelled "bought with this collection's fees".
- **Records:** the admin floor-fund page shows each bid, fill and cancel.

## Open

- [ ] nft-data: filtered 7-day sales floor per collection (endpoint and method; P10 of filtered sales vs min of the last N).
- [ ] Source for "cheapest listing elsewhere" (bot only).
- [ ] AWS Admin: KMS key for the bidding wallet.
- [ ] Daily spend cap per collection (ETH).
