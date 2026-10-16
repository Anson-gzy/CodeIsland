#!/bin/bash
# Launch the island app on a temp endpoint, prove the HTTP round trip through it, then quit it.
set -u
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -q || exit 1
T=$(mktemp -d); export ASK_ISLAND_ENDPOINT="$T/endpoint.json"
.build/debug/AskIsland & APP=$!
trap 'kill $APP 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 30); do [ -s "$ASK_ISLAND_ENDPOINT" ] && break; sleep 0.2; done
[ -s "$ASK_ISLAND_ENDPOINT" ] || { echo "no endpoint file"; exit 1; }
[ "$(stat -f %Lp "$ASK_ISLAND_ENDPOINT")" = 600 ] || { echo "endpoint perms"; exit 1; }
.build/debug/ask-island ask "smoke?" -o A -o B --timeout 2; rc=$?
[ $rc -eq 4 ] || { echo "expected timeout exit 4, got $rc"; exit 1; }
kill -0 $APP || { echo "app died"; exit 1; }
echo "smoke ok"
