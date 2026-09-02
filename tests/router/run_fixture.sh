#!/bin/bash
# Run generator fixtures against installed scripts on the router.
# Usage: tests/router/run_fixture.sh <fixture-dir> [--server]
set -uo pipefail

FIXTURE="$1"
MODE="${2:-client}"
FIXROOT="$(cd "$(dirname "$0")"; pwd)"
WORK="/tmp/hp-fixture"
LIVE_CONFIG="/etc/config/homeproxy"

rm -rf "$WORK"
mkdir -p "$WORK"

# ucode's uci plugin always reads /etc/config; isolate by temporarily
# swapping the config file and restoring it on exit.
cp -a "$LIVE_CONFIG" "$WORK/live-backup"
cp "$FIXROOT/fixtures/$FIXTURE/config/homeproxy" "$LIVE_CONFIG"
restore_config() {
	cp -a "$WORK/live-backup" "$LIVE_CONFIG"
}
trap restore_config EXIT

if [ "$MODE" = "server" ]; then
	GEN="/etc/homeproxy/scripts/generate_server.uc"
else
	GEN="/etc/homeproxy/scripts/generate_client.uc"
fi

ucode "$GEN" >/tmp/hp-fixture.out 2>&1
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

EXPECT="$FIXROOT/fixtures/$FIXTURE/expect.txt"
while IFS= read -r pat; do
	[ -z "$pat" ] && continue
	case "$pat" in
		\!*) if grep -qF "${pat#!}" "$JSON"; then
			echo "FAIL($FIXTURE): unexpected string: ${pat#!}"
			exit 1
		fi ;;
		*) if ! grep -qF "$pat" "$JSON"; then
			echo "FAIL($FIXTURE): missing expected string: $pat"
			exit 1
		fi ;;
	esac
done < "$EXPECT"

echo "PASS($FIXTURE)"
