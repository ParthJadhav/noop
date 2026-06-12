#!/usr/bin/env bash
# Refresh the release-time-stamped community stats shown by the in-app donation nudge.
#
# The app is fully offline by design — it never fetches these itself. Instead, run this
# before each release: it reads the GitHub release API (total asset downloads) and the
# public donation-address explorers (distinct incoming transactions = donors), then
# rewrites the constants in BOTH platforms' DonationStats so they stay in lockstep:
#   Strand/Screens/DonationNudgeCard.swift           (Swift: macOS + iOS)
#   android/app/src/main/java/com/noop/ui/DonationNudge.kt  (Kotlin)
#
# Downloads are floored to the nearest 500 ("5,000+") so the line reads honestly between
# releases. Donors = confirmed incoming BTC outputs + incoming ETH txs.
#
# Usage: Tools/update-donation-stats.sh   (no args; needs curl + python3; GH token optional)
set -euo pipefail
cd "$(dirname "$0")/.."

BTC="bc1qn2gkl7wslwpws06mvazjn2uu689zlkv7kg3kf5"
ETH="0xd64D508b531c4b1297Ca4023C774e0E97aA67B7F"

AUTH=()
if [ -f "$HOME/.config/noop/gh_token" ]; then
  AUTH=(-H "Authorization: token $(cat "$HOME/.config/noop/gh_token")")
fi

# Paginate — the repo has >100 releases; a single page silently undercounts.
downloads=$(for page in 1 2 3 4; do
  curl -s "${AUTH[@]}" "https://api.github.com/repos/NoopApp/noop/releases?per_page=100&page=$page"
done | python3 -c "
import json, sys
total = 0
dec = json.JSONDecoder()
buf = sys.stdin.read().strip()
while buf:
    arr, idx = dec.raw_decode(buf)
    total += sum(a['download_count'] for r in arr for a in r['assets'])
    buf = buf[idx:].lstrip()
print(total)")

btc_donors=$(curl -s "https://mempool.space/api/address/$BTC" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['chain_stats']['funded_txo_count'])")

# Incoming ETH txs (best-effort; 0 if the explorer is unreachable).
eth_donors=$(curl -s "https://eth.blockscout.com/api/v2/addresses/$ETH/transactions?filter=to" \
  | python3 -c "import json,sys
try: print(len(json.load(sys.stdin).get('items',[])))
except Exception: print(0)" 2>/dev/null || echo 0)

floored=$(( downloads / 500 * 500 ))
donors=$(( btc_donors + eth_donors ))

echo "downloads=$downloads (floored $floored), donors: btc=$btc_donors eth=$eth_donors total=$donors"

python3 - "$floored" "$donors" <<'EOF'
import re, sys
floored, donors = sys.argv[1], sys.argv[2]

p = 'Strand/Screens/DonationNudgeCard.swift'
s = open(p).read()
s = re.sub(r'static let downloads = [\d_]+', f'static let downloads = {int(floored):_}', s)
s = re.sub(r'static let donors = \d+', f'static let donors = {donors}', s)
open(p, 'w').write(s)

p = 'android/app/src/main/java/com/noop/ui/DonationNudge.kt'
s = open(p).read()
s = re.sub(r'const val DOWNLOADS = [\d_]+', f'const val DOWNLOADS = {int(floored):_}', s)
s = re.sub(r'const val DONORS = \d+', f'const val DONORS = {donors}', s)
open(p, 'w').write(s)
print('✓ DonationStats updated on both platforms')
EOF
