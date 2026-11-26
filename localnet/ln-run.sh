#!/usr/bin/env bash
# ln-run.sh <script.canton> [extra docker -e args...] : run a Canton console script against LocalNet.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; S="$1"; shift
# Library + script are concatenated into state/ so one console run gets both.
C="state/run-$(basename "$S")"; if [ "$(basename "$S")" != ln-probe.canton ] && [ "$(basename "$S")" != ln-rate0.canton ]; then cat "$D/ln-lib.canton" "$D/$S" > "$D/$C"; else cp "$D/$S" "$D/$C"; fi
TOKEN=$(python3 - <<'PY'
import hmac,hashlib,base64,json
b=lambda x: base64.urlsafe_b64encode(x).rstrip(b"=")
h=b(json.dumps({"alg":"HS256","typ":"JWT"}).encode()); p=b(json.dumps({"sub":"ledger-api-user","aud":"https://canton.network.global"}).encode())
print((h+b"."+p+b"."+b(hmac.new(b"unsafe",h+b"."+p,hashlib.sha256).digest())).decode())
PY
)
docker run --rm -i --network localnet -v "$D:/fred" -v "$(cd "$D/.." && pwd)/artifacts:/artifacts:ro" -e TOKEN="$TOKEN" "$@" \
  --entrypoint /app/bin/canton ghcr.io/digital-asset/decentralized-canton-sync/docker/canton:0.6.11 \
  run "/fred/$C" -c /fred/ln-remote.conf --no-tty < /dev/null
