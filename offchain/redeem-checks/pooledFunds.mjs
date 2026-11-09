// Redeem release gate 3: refuse payments made with PC pooled from many throwaway wallets.
// (Gate 1: a registered Pentagon user. Gate 2: Bronze Key member or above. See
// docs/REDEEM-RELEASE-GATES.md.)
//
// nftprof 2026-11-09, after drop #13: about 2,100 single-use wallets each took a 0.001 PC drip
// from the ATS faucet and swept it to one wallet, which then claimed a Redeem piece. "Price is
// right, but we shouldn't encourage aggregated accounts." A pooled payment is never released;
// the buyer reclaims their PC after the 7-day window (VaultDrops.reclaimBid / reclaimFor).
//
// Reads only the public Pentagon Chain explorer (Blockscout API v2). No keys, no writes.

export const DEFAULTS = {
  explorer: 'https://explorer.pentagon.games/api/v2',
  smallWei: 5n * 10n ** 16n, // a "small" inbound transfer: under 0.05 PC
  minSenders: 20, // fewer distinct small senders than this is never pooling
  sample: 10, // senders inspected one by one
  throwawayMaxTxs: 3, // a sender with at most this many lifetime txs is single-use
  throwawayShare: 0.7, // share of sampled senders that must be single-use
  pooledShareOfPrice: 0.25, // small inflows must cover at least this share of the price
  maxPages: 40, // 50 txs a page; past this the wallet is treated as pooled
};

// Faucets and drip contracts on Pentagon Chain (3344), lowercase.
export const KNOWN_FAUCETS = {
  '0xd9078a82fdce91632dd6b6749e9ac0932095f49a': 'ATS / AgentCert faucet',
  '0x6e5f8fb602dd598e0c30ec2ed29d0f0d81a8f464': 'PC Faucet',
  '0xdd4e3a4a19d7bda1df1ad48dc06880a012992497': 'PC Faucet (DNA gas)',
};

async function getJson(url) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(url, { headers: { accept: 'application/json' } });
    if (res.ok) return res.json();
    if (attempt >= 3 || (res.status !== 429 && res.status < 500)) {
      throw new Error(`explorer ${res.status} for ${url}`);
    }
    await new Promise((r) => setTimeout(r, 1000 * (attempt + 1)));
  }
}

/**
 * @param {string} payer          the wallet that paid the claim (VaultDrops highestBidder)
 * @param {object} opts
 * @param {bigint} opts.priceWei  the claim price in wei
 * @param {number} [opts.before]  unix seconds; only inflows before the claim count
 * @returns {Promise<{pooled: boolean, reasons: string[], stats: object}>}
 */
export async function checkPooledFunds(payer, opts) {
  const o = { ...DEFAULTS, ...opts };
  const me = payer.toLowerCase();
  const beforeMs = o.before ? o.before * 1000 : Infinity;

  // 1. Every incoming native transfer before the claim.
  const small = new Map(); // sender -> total wei
  let pooledWei = 0n;
  let pages = 0;
  let truncated = false;
  let params = '';
  for (;;) {
    const page = await getJson(`${o.explorer}/addresses/${me}/transactions?filter=to${params}`);
    pages++;
    for (const t of page.items ?? []) {
      if (t.status !== 'ok' || !t.to || t.to.hash.toLowerCase() !== me) continue;
      if (Date.parse(t.timestamp) >= beforeMs) continue;
      const v = BigInt(t.value);
      if (v === 0n || v >= o.smallWei) continue;
      const from = t.from.hash.toLowerCase();
      small.set(from, (small.get(from) ?? 0n) + v);
      pooledWei += v;
    }
    if (!page.next_page_params) break;
    if (pages >= o.maxPages) { truncated = true; break; }
    params = '&' + new URLSearchParams(page.next_page_params).toString();
  }

  const stats = { smallSenders: small.size, pooledWei: pooledWei.toString(), pages, truncated };
  if (small.size < o.minSenders) return { pooled: false, reasons: [], stats };

  // 2. Are the senders single-use wallets? Inspect an evenly spread sample.
  const senders = [...small.keys()];
  const step = Math.max(1, Math.floor(senders.length / o.sample));
  const picked = senders.filter((_, i) => i % step === 0).slice(0, o.sample);
  let throwaway = 0;
  const faucets = new Set();
  for (const s of picked) {
    const c = await getJson(`${o.explorer}/addresses/${s}/counters`);
    if (Number(c.transactions_count) > o.throwawayMaxTxs) continue;
    throwaway++;
    const internal = await getJson(`${o.explorer}/addresses/${s}/internal-transactions`);
    for (const it of internal.items ?? []) {
      const name = KNOWN_FAUCETS[it.from?.hash?.toLowerCase()];
      if (name) faucets.add(name);
    }
  }
  const share = throwaway / picked.length;
  Object.assign(stats, { sampled: picked.length, throwaway, faucets: [...faucets] });

  const coversPrice = pooledWei * 100n >= o.priceWei * BigInt(Math.round(o.pooledShareOfPrice * 100));
  const reasons = [];
  if (truncated) reasons.push(`more than ${o.maxPages * 50} incoming transfers; too many to verify`);
  if (share >= o.throwawayShare && coversPrice) {
    reasons.push(`${small.size} wallets sent small amounts, and ${throwaway} of ${picked.length} checked were single-use`);
  }
  if (reasons.length && faucets.size) reasons.push(`funded from: ${[...faucets].join(', ')}`);
  return { pooled: reasons.length > 0, reasons, stats };
}
