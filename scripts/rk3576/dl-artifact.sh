#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# dl-artifact.sh - download a GitHub Actions artifact to a local file.
#
# Usage: dl-artifact.sh <repo> <run-id> [artifact-name-substring] [out-file]
#
# The GitHub API redirects to a signed Azure blob URL that expires after about
# ten minutes, so the URL is refreshed and the transfer is resumed whenever it
# breaks.

set -uo pipefail

REPO="${1:?repo required}"
RUN="${2:?run id required}"
WANT="${3:-}"
OUT="${4:-/tmp/artifact.zip}"
STATUS="${OUT}.status"

API="https://api.github.com"
UA="curl-artifact-downloader"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

# The API needs a token. Reuse the gh CLI credential when available.
if [ -z "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    GH_TOKEN="$(gh auth token 2>/dev/null || true)"
    export GH_TOKEN
fi
if [ -z "${GH_TOKEN:-}" ]; then
    say "ERROR: no GitHub token (set GH_TOKEN or run 'gh auth login')"
    echo "FAILED" > "$STATUS"
    exit 1
fi

# Locate the artifact id.
ART_ID=""
ART_NAME=""
for attempt in 1 2 3; do
    json=$(curl -sS -H "Accept: application/vnd.github+json" \
                  -H "User-Agent: $UA" \
                  ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
                  "$API/repos/$REPO/actions/runs/$RUN/artifacts" 2>/dev/null)
    if [ -z "$json" ] || echo "$json" | grep -q '"message"'; then
        say "artifact list fetch failed, retry $attempt"
        sleep 5
        continue
    fi
    # Parse with python: the API returns pretty-printed JSON, so a plain
    # grep for "name":"..." does not match.
    pick=$(printf '%s' "$json" | python3 -c '
import json, sys
want = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
arts = data.get("artifacts") or []
if want:
    for a in arts:
        if a.get("name") == want:
            print(a.get("id", ""), a.get("name", ""))
            break
else:
    for a in arts:
        print(a.get("id", ""), a.get("name", ""))
        break
' "$WANT" 2>/dev/null)
    if [ -n "$pick" ]; then
        ART_ID=$(echo "$pick" | awk '{print $1}')
        ART_NAME=$(echo "$pick" | cut -d' ' -f2-)
    fi
    [ -n "$ART_ID" ] && break
    say "artifact not found (want='$WANT'), retry $attempt"
    sleep 5
done

if [ -z "$ART_ID" ]; then
    say "ERROR: could not find artifact (run=$RUN want='$WANT')"
    echo "FAILED" > "$STATUS"
    exit 1
fi
say "artifact id = $ART_ID ($ART_NAME)"

# The signed blob URL lives in the Location header of the API response.
signed_url() {
    curl -sS -D - -o /dev/null \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: $UA" \
        ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
        "$API/repos/$REPO/actions/artifacts/$ART_ID/zip" \
        2>/dev/null \
    | tr -d '\r' \
    | awk 'BEGIN{IGNORECASE=1} /^location:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}'
}

: > "$STATUS"
attempt=0
while [ $attempt -lt 12 ]; do
    attempt=$((attempt + 1))
    URL="$(signed_url)"
    if [ -z "$URL" ]; then
        say "attempt $attempt: could not obtain signed URL, retry in 10s"
        sleep 10
        continue
    fi
    # Resume an interrupted transfer; start from scratch on the first try.
    if [ -s "$OUT" ]; then
        say "attempt $attempt: resuming at $(stat -c%s "$OUT") bytes"
        curl -sS -L -C - --retry 3 --retry-delay 5 \
             --connect-timeout 20 --max-time 900 \
             -o "$OUT" "$URL"
    else
        say "attempt $attempt: downloading (signed URL acquired)"
        curl -sS -L --retry 3 --retry-delay 5 \
             --connect-timeout 20 --max-time 900 \
             -o "$OUT" "$URL"
    fi
    rc=$?
    if [ $rc -eq 0 ] && unzip -tqq "$OUT" >/dev/null 2>&1; then
        say "download OK: $OUT ($(stat -c%s "$OUT") bytes)"
        echo "DONE" > "$STATUS"
        exit 0
    fi
    say "attempt $attempt incomplete (curl rc=$rc), refreshing URL"
    sleep 10
done

say "ERROR: download did not complete"
echo "FAILED" > "$STATUS"
exit 1
