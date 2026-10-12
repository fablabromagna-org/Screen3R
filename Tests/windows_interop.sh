#!/usr/bin/env bash
#
# Runs the Windows sender's protocol code (Windows/Screen3R/PeerConnection.cs & co.) against a
# simulated viewer that uses the Mac apps' C crypto (Shared/rd_crypto.c). Linux or macOS with
# .NET 10, Python 3 and OpenSSL 3 (Linux):
#
#   Tests/windows_interop.sh
#
# Three sessions: pairing, reconnection with the stored key, and an unencrypted session.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cc -O2 -fPIC -shared -I Shared Shared/rd_crypto.c Tests/rd_ecdh_openssl.c -lcrypto -o "$WORK/librd.so"
dotnet build -c Release -nologo -v q Windows/Screen3R.Tests -o "$WORK/tests" >/dev/null
dotnet "$WORK/tests/Screen3R.Tests.dll"

session() {   # $1 = title, $2 = encrypt (1/0)
  echo "== $1"
  local port=$((40000 + RANDOM % 20000))
  python3 Tests/fake_viewer.py "$WORK/librd.so" "$port" "$WORK/viewer.json" > "$WORK/viewer.log" 2>&1 &
  local viewer=$!
  sleep 0.5
  local host=0
  dotnet "$WORK/tests/Screen3R.Tests.dll" interop "$port" "$WORK/host-keys.json" "$2" > "$WORK/host.log" 2>&1 || host=$?
  local view=0
  wait "$viewer" || view=$?
  sed 's/^/   viewer: /' "$WORK/viewer.log"
  sed 's/^/   host:   /' "$WORK/host.log"
  if [ "$host" -ne 0 ] || [ "$view" -ne 0 ]; then echo "FAILED: $1"; exit 1; fi
}

session "first connection: pairing, encrypted" 1
grep -q "GATE cry=always" "$WORK/host.log" || { echo "FAILED: the HELLO gate was not used"; exit 1; }
VCODE="$(sed -n 's/^VIEWER CODE //p' "$WORK/viewer.log")"
HCODE="$(sed -n 's/^CODE \([0-9]*\) \([0-9]*\) .*/\1\2/p' "$WORK/host.log")"
[ -n "$VCODE" ] && [ "$VCODE" = "$HCODE" ] || { echo "FAILED: pairing codes differ ($HCODE / $VCODE)"; exit 1; }
echo "   both sides showed the code $VCODE"
session "second connection: stored key, encrypted" 1
grep -q "AUTH ok" "$WORK/viewer.log" || { echo "FAILED: the stored key was not used"; exit 1; }
session "third connection: not encrypted" 0
echo "Interop OK: the Windows sender and the Mac viewer's crypto agree."
