// Usage: node check-drop.mjs <dropId>
// Runs release gate 2 (pooled funds) against a Redeem claim from the public drops API.
import { checkPooledFunds } from './pooledFunds.mjs';

const DROPS = 'https://market13.pentagon.games/api/market/drops';
const id = Number(process.argv[2]);
if (!Number.isInteger(id)) {
  console.error('usage: node check-drop.mjs <dropId>');
  process.exit(2);
}

const { drops } = await (await fetch(DROPS)).json();
const d = drops.find((x) => x.id === id);
if (!d || !d.highestBidder) {
  console.error(`drop ${id}: not found or not claimed`);
  process.exit(2);
}

const r = await checkPooledFunds(d.highestBidder, {
  priceWei: BigInt(d.highestBid) * 10n ** 18n,
  before: d.settledAt,
});
console.log(JSON.stringify({ drop: id, payer: d.highestBidder, ...r }, null, 2));
process.exit(r.pooled ? 1 : 0);
