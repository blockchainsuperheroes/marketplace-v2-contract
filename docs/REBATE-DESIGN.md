# Buyer fee rebate (design, not built)

Buyers pay a 2.5% fee on MarketplaceV3, and 2% of the price comes back to them as PC.
This file collects the design so far: nftprof's decisions (2026-10-31) and the Bridge2 session's review.

## Rules

- **Source of truth:** `Sale` events from MarketplaceV3 (buyer, price, fee, tx hash, log index).
- **Replay key:** `keccak(saleTxHash, logIndex)`.
- **48h hold** before a sale's rebate can be claimed.
- **No rebate** when the NFT returns to an owner it had in the previous 7 days.
- **Caps are in PC, not ETH:** a per-wallet daily cap, so a manipulated rate can't raise the payout past it.

## Wash-trade arithmetic (the safety argument)

A self-dealt sale costs `fee + royalty` and earns `rebate`. The rebate is only safe while
`fee + royalty > rebate`. Today that is 2.5% + 2.5% > 2%.

- **Registered creator washing their own collection:** the royalty goes back to them, so it costs only the 2.5% fee. They pay 0.5% net in ETH and receive 2% in PC, about a 75% discount on PC, repeatable at any size.
- **Chained wash trades** (A→B→C→D, each pair new, so nothing returns) slip past both the 7-day rule and per-wallet caps, because addresses are free.

Mitigations:
- **Rebate only for registered PG members.** This resists fake identities; address-based caps can't.
- **No rebate when the collection's royalty receiver is the buyer or the seller.**
- **The contract rejects self-buy and self-fill** (`SelfTrade`).
- **`defaultRoyaltyBps` is part of this argument.** Lowering it or the fee below the rebate opens a money pump. Re-run this check before changing either.

## Rails

The Redeem store accepts both, so the rebate can use either.

1. **PG Balance credit for registered PG members.** This is the simplest rail: no destination, no payout contract, no signers, no pool.
   - Destination is `walletinfo.aa_wallet_address` only.
   - Never use `aa2_address`, and never branch on `has_aa2`.
2. **Native PC on Pentagon Chain for everyone else.** It must be **claimed, not pushed**: the buyer connects the buying wallet and nominates a Pentagon address.
   - A Safe or other contract wallet doesn't exist at the same address on Pentagon, so a push would strand the PC.

## Native-PC payout contract

The bridge's `PCPayout` must not be reused. It only pays against bridge deposits, and a generic payout path is how the old bridge was drained.

- **Separate contract, separate funded pool, separate signers.**
- **2-of-2 EIP-712**, domain name `PentagonRebate`, distinct from Bridge2 / Stake / the other domains.
- **Accruing budget guard**, copied from `PCStakeLedger` rather than rewritten.
  - Settle at the old rate before changing the rate.
  - Set `budgetUpdated = block.timestamp` on every change (never back-dated).
  - The cap must exceed the largest single legitimate rebate.
  - Size it from a busy day, not an average one.
- **Effects before interaction.**

## Verifier independence

Copy the pattern of `bridge2/keeper/src/verifier.js`.

- The verifier runs on its own host, with its own RPC and its own key.
- It accepts **only** `(saleTxHash, logIndex)`, then re-derives buyer, amount and rate itself.
- Acceptance tests:
  1. It refuses a sale that does not exist.
  2. Given a wrong amount, it signs the on-chain value or refuses.
- Do not run it on the Bridge2 signer boxes (they hold the bridge's signing keys and are split between two operators).

## Rate (ETH → PC)

nftprof wants Uniswap on Ethereum as the official rate.

- **PC on Ethereum:** `0xA1Aa371E450C5AeE7fff259cbF5ccA9384227272`.
- **Pin the PC/WETH pair:** `0x41d370fc4c9d92d45fbbe7ff31482c5a05d129cc` (about 55 WETH, thin).
  - Never use the PC/USDC pair `0x7f69880b…`, which is effectively dead.
- **Proposed rate:** a 24h TWAP published daily as a fixed rate.
- **Guards:**
  - **Liquidity floor:** fail closed and queue if WETH reserves fall below a threshold.
  - **Deviation band:** a rate more than X% from the previous one queues for manual release.
  - **Floor and ceiling** on PC per ETH, set by admin.
- **TWAP implementation:** use `UniswapV2OracleLibrary.currentCumulativePrices`, which includes the counterfactual update since the last `sync`. A naive read of `price0CumulativeLast` on a quiet pool is just the last trade price.
- **Wording:** in-ecosystem PC is described as having no cash value. Check a market-derived rate against that wording with whoever owns the legal position.
