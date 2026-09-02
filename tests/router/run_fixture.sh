#!/bin/bash
# Run generator fixtures against installed scripts on the router.
# Usage: tests/router/run_fixture.sh <fixture-dir> [--server]
set -uo pipefail

FIXTURE="$1"
MODE="${2:-client}"
ROOT="$(cd "$(dirname "$0")/../.."; pwd)"
WORK="/tmp/hp-fixture"

rm -rf "$WORK"
mkdir -p "$WORK/config"
cp "$ROOT/tests/router/fixtures/$FIXTURE/config/homeproxy" "$WORK/config/homeproxy"

if [ "$MODE" = "server" ]; then
	GEN="/etc/homeproxy/scripts/generate_server.uc"
else
	GEN="/etc/homeproxy/scripts/generate_client.uc"
fi

UCI_CONFIG_DIR="$WORK/config" ucode "$GEN" >/tmp/hp-fixture.out 2>&1
RC=$?
if [ $RC -ne 0 ]; then
	echo "FAIL($FIXTURE): generator exited $RC"
	cat /tmp/hp-fixture.out
	exit 1
fi

if [ "$MODE" = "server" ]; then
	JSON="/var/run/homeproxy/sing-box-s.json"
else
	JSON="/var/run/homeproxy/sing-box-c.json"
fi

/usr/bin/sing-box check --config "$JSON" >/tmp/hp-check.out 2>&1
RC=$?
if [ $RC -ne 0 ]; then
	echo "FAIL($FIXTURE): sing-box check exited $RC"
	cat /tmp/hp-check.out
	exit 1
fi

EXPECT="$ROOT/tests/router/fixtures/$FIXTURE/expect.txt"
while IFS= read -r pat; do
	[ -z "$pat" ] && continue
	if ! grep -qF "$pat" "$JSON"; then
		echo "FAIL($FIXTURE): missing expected string: $pat"
		exit 1
	fi
done < "$EXPECT"

echo "PASS($FIXTURE)"
