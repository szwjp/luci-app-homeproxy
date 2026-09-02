#!/bin/sh
# Verify init.d refuses to start when sing-box < 1.14.
set -e

mkdir -p /var/run/homeproxy
mkdir -p /tmp/sb113
cat > /tmp/sb113/sing-box <<'EOF'
#!/bin/sh
if [ "$1" = "version" ] && [ "$2" = "-n" ]; then
	echo "1.13.21"
	exit 0
fi
exec /usr/bin/sing-box "$@"
EOF
chmod +x /tmp/sb113/sing-box

: > /var/run/homeproxy/homeproxy.log
PATH="/tmp/sb113:$PATH" /etc/init.d/homeproxy start >/tmp/ver-gate.out 2>&1 || true
grep -q "sing-box >= 1.14.0 required" /var/run/homeproxy/homeproxy.log || {
	echo "FAIL: expected version error in homeproxy.log"
	exit 1
}
echo "gate log contents:"
cat /var/run/homeproxy/homeproxy.log
echo "PASS(version-gate)"
