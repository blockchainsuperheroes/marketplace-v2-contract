# Redeem release gates

Set by nftprof on 2026-11-09, after drop #13. About 2,100 throwaway wallets each took a 0.001 PC drip from the ATS faucet and swept it to one wallet, which then claimed Roboto Helmeto #7513 for 2 PC. "Price is right, but we shouldn't encourage aggregated accounts. We designed the 7 days hold and manual release for exactly this reason."

Redeem is the members' site for Bronze Key members and above. A claim is released only when all three gates pass, checked in order:

| # | Gate | Passes when | Applies to |
|---|---|---|---|
| 1 | **Registered** | The paying wallet belongs to a Pentagon account by a proven link (`mm_address` or `penai_address`). A Points payment passes, since it comes from the account itself. `user_external_wallets` never counts. | All claims |
| 2 | **Bronze Key or above** | The account's effective VIP tier is Bronze Key or higher when the release is checked | All claims |
| 3 | **Not pooled** | The PC wasn't gathered from many throwaway wallets (`offchain/redeem-checks/pooledFunds.mjs`) | PC payments (Points can't be pooled from wallets) |

The existing checks and release timing (1h / 24h / 72h, the daily cap) come after the gates. A failed gate is never released, automatically or by the review queue. The buyer reclaims their PC after the 7-day window (`VaultDrops.reclaimBid`, or anyone can call `reclaimFor`). nftprof can still release by hand from 0xB2e3.

**Gates 1 and 2 can be fixed after a claim.** A buyer who registers or upgrades is released at the 72h timing (a new binding), as long as the 6-day release cut-off hasn't passed. Gate 3 has no fix: pay again from a wallet funded directly, or with Points.

## Gates 1 and 2: the lookup

**Live since 2026-11-09** (pg-vip-api main d9db306, deployed on nftprof's go). With no key it returns 401; the drop #13 buyer returns `registered:false`. The key (`RELEASE_CHECK_KEY`) is held only in pg-vip-api's env on pg-identity. Our server gets it when the verifier or pre-check server exists, piped over SSH or handed over by nftprof, never printed.
- **Request:** `POST https://api.account.pentagon.games/user/vip/release_check` with header `Api-Key: <RELEASE_CHECK_KEY>`. The key is scoped to PFP Vault only, rate-limited, and set in our server env at deploy time. The body is `{"wallet":"0x…"}`. For Points, it's `{"pg_user_id":N,"wallet":"0x<deliverTo>"}`.
- **Response:** `registered`, `tier_at_least_bronze`, `linked_at`, `link` (mm or penai). For Points, `wallet_is_this_users` too (requested). Nothing personal.
- **Registered** means exactly one live account holds the wallet as a bound `mm_address` or as `penai_address`. An address claimed by two or more accounts doesn't count.
- **Bronze Key** is tier 1; Paper Ticket and Iron Pass are free ranks. `tier_status: "unknown"` means hold, not fail.
- **The hold signal is `recent_link`, not `linked_at`.** An external-wallet link (`mm_address`: any self-custody EOA such as MetaMask or Rabby, not only MetaMask) is permanent once made, and the 543K existing binds have no bind time, so `linked_at: null` means old and trusted. `recent_link` is true for a penai link made in the last 7 days. It must also be true for a new external-wallet link: Live, `recent_link` is true for an account created in the last 7 days, or (for an mm link) an account saved in the last 7 days. The second rule over-holds about 106 of 543K accounts. A bind time for new external-wallet links is requested from identity; it will also catch an old account that links a new wallet.
- **Decision:**
  - release when `registered` and `tier_at_least_bronze` and not `recent_link` (for Points, also `wallet_is_this_users`);
  - 72h timing when `recent_link`;
  - hold when `tier_status: "unknown"`.
- **The website's pre-payment check calls through our own server.** The key never reaches a browser, or the endpoint becomes a public "is this wallet a VIP" lookup.

## Gate 3: pooled funds

The check reads only the public Pentagon Chain explorer.
1. List the payer's incoming PC transfers before the claim. Count the distinct senders of small transfers (under 0.05 PC each). Fewer than 20 always passes.
2. Inspect 10 of those senders, spread evenly. A sender with at most 3 lifetime transactions is single-use.
3. **Pooled** when both hold:
   - at least 7 of the 10 sampled senders are single-use;
   - the small inflows add up to at least 25% of the price.

   A wallet with more than 2,000 incoming transfers is also treated as pooled, because it's too big to verify.
4. The reasons name any known faucet that funded the senders (ATS, PC Faucet, DNA gas).

All thresholds are in `DEFAULTS`.

Checked on 2026-11-09 with `node offchain/redeem-checks/check-drop.mjs <id>`:
- **Drop 13:** pooled. Over 2,000 small senders, 10 of 10 single-use, funded by the ATS faucet.
- **Drops 4, 11 and 12:** pass.

The check also runs **before payment** on the website, so honest buyers aren't stuck for 7 days. The contract can't stop a direct call, so the release check is the one that counts.

## What the buyer sees

Show one gate at a time, and never show the next gate until the one before passes.
- **Gate 1:** "Redeem is for Pentagon members. This wallet isn't linked to a Pentagon account yet. Sign in or create your account, then link this wallet." (Sign in with Pentagon, then a wallet signature.)
- **Gate 2:** "Redeem is for Bronze Key members and above." Link to members.pentagon.games.
- **Gate 3:** "This wallet's PC was gathered from many other wallets, so it can't be used on Redeem. Pay from a wallet you funded directly, or with Points."
- **On a held claim:** the message of the first failing gate, plus "Not released. Your PC can be reclaimed from <date>."
- **Site-wide, low-key** (in place, as if it was always there; no "new" badge or announcement): "Redeem is the members' site for Bronze Key members and above."

Copy rules still apply: no "cash out", no price claims.

## The admin release page

nftprof, 2026-11-09: a claim that fails a gate must be obviously red-flagged on the release page, with the reason.

On `market13.pentagon.games/admin/release` (CI/CD owns this page), every waiting claim gets a gate row:
- **Pass:** a green "Gates passed" line.
- **Fail:** a red card with a red "DO NOT RELEASE" header. It lists each failing gate in plain words, e.g.:
  - "Gate 1: not a registered Pentagon user";
  - "Gate 3: PC pooled from 2,000+ single-use wallets (ATS faucet)".

  Then "Buyer can reclaim from <date>". The Sign/Release button is disabled. An override needs a typed confirmation (the drop id), and the override is logged.
- **Unknown** (the lookup failed, or `tier_status: unknown`): an amber "Hold: gates not checked" card. The button is disabled the same way.
- **Data source:** the indexer computes the gates server-side (`/vip/release_check` with the key from server env, plus `pooledFunds.mjs`) and caches them per drop for about 10 minutes. The page never sees the key.
- **Held list:** drops on it (today, drop 13) always show red, with the reason, even if a lookup is down.

## The buyer's journey on a held claim

nftprof, 2026-11-09: the buyer is guided step by step: create an account, then become a paying member, and only then told about pooled PC. One step on screen at a time.

The buyer's own claim card on Redeem (wallet connected, "My claims"), always with: the piece, "Paid 2 PC", "Reclaim available from <date>".

**Step 1: not registered.** Status: "Waiting for your account".
- "Redeem is the members' site. This wallet isn't linked to a Pentagon account yet."
- [Create your Pentagon account] → sign up, then sign the wallet link.
- Small print: "Your claim stays reserved while you finish. Release checks continue after each step."

**Step 2: registered, below Bronze Key.** Status: "Waiting for membership".
- "Redeem is for Bronze Key members and above."
- [Become a Bronze Key member] → members.pentagon.games, which shows the Stripe payment. The payment shows up in `release_check` as `tier_at_least_bronze`.
- Same small print.

**Step 3: member, PC pooled.** Status: "Can't be released".
- "This claim was paid with PC gathered from many other wallets, which Redeem doesn't accept. Your membership stays active. You can reclaim your 2 PC from <date>, and buy again with Points or from a wallet you funded directly."
- [Reclaim my PC], enabled from the date.

**All pass:** "Checks passed. Delivery within <timing>". The usual release timing applies, and new accounts get 72h.

**Honesty rule.** No step may promise release. Steps 1 and 2 always say that more checks follow. Membership is sold as membership, never as "pay to release this claim".

**No account means no email.** A wallet without an account can only be reached on the site, so the card is the only channel until step 1 is done.
