# MarketplaceV3 on Ethereum: early release checklist

This is the early release: **only our own NFTs are allowed**, which keeps the risk low.
A professional audit comes before third-party collections are allowed.

## Decide before deploying (nftprof)

- [ ] **Treasury wallet**: where the 2.5% buyer fee goes.
- [ ] **Floor-fund wallet**: where unregistered collections' 2.5% royalty goes.
  - Keep it a separate wallet from the treasury, so the floor buys can be accounted for.
- [ ] **Launch collections**: our own Ethereum collections only. List the contract addresses.
- [ ] **Creator royalties for those collections**: receiver and bps (≤ 1000).
  - Or leave them unregistered, so their royalty goes to the floor fund.
- [ ] **Deployer**: a fresh throwaway wallet with about 0.01 ETH.
  - It owns the contract only during the script, then hands ownership to 0xB2e3 (two-step).

## Deploy

```bash
TREASURY=0x… FLOOR_FUND=0x… COLLECTIONS=0x…,0x… \
ROYALTY_COLLECTIONS=0x… ROYALTY_RECEIVERS=0x… ROYALTY_BPS_LIST=500 \
forge script script/DeployMarketplaceV3.s.sol --rpc-url $ETH_RPC --broadcast --verify \
  --private-key-file <throwaway key file>   # or --ledger
```

- Compile with the repo settings: solc 0.8.24, cancun, via_ir, 200 runs.
- `--verify` needs `ETHERSCAN_API_KEY`. The source must be verified on Etherscan, unlike V2 on Pentagon.

## Right after

1. 0xB2e3 calls `acceptOwnership()`. Until then the deployer is still the owner, so do it immediately.
2. Check on Etherscan:
   - `owner()` is 0xB2e3 and `pendingOwner()` is 0;
   - `feeBps()` is 250 and `defaultRoyaltyBps()` is 250;
   - `treasury()` and `floorFund()` are right;
   - `collectionAllowed()` is true for each launch collection;
   - `royaltyFor()` is right for each.
3. Smoke test with one cheap NFT of ours:
   - list, buy from a second wallet, check the payouts (seller price − royalty; treasury fee; royalty receiver);
   - place an offer, accept it, cancel a second offer.
4. Put the address into the frontend's `lib/marketV3.ts` (chain 1). The V3 UI turns on per chain.
5. Keeper job: watch `Transfer` events of the allowed collections and call `clearStale` for listings whose seller no longer holds the NFT.

## Emergency

- `pause()` stops list, buy, placeOffer and acceptOffer. Cancels, delists and withdrawals keep working.
- `setCollectionAllowed(c, false)` stops one collection.
- Retiring: `pause()`, then `refundOffers(ids)` returns escrow to bidders (owner only, while paused).

## Before allowing third-party collections

- External audit. The self-run tool results are in `docs/AUDIT-SELF-REVIEW.md`.
- The creator royalty claim page and the floor-fund dashboard are live.
- The rebate rules are settled. See docs/REBATE-DESIGN.md: fee + royalty must stay above the 2% rebate.
