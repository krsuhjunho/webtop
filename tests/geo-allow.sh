#!/usr/bin/env bash
# GeoIP must see the real client address and fail closed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKDIR=$(mktemp -d)
MMDB="$WORKDIR/GeoLite2-Country.mmdb"
LOGS="$WORKDIR/logs"
mkdir -p "$LOGS"

cleanup() {
  sudo docker rm -f webtop-nginx geo-peer >/dev/null 2>&1 || true
  sudo ip netns del geo-test >/dev/null 2>&1 || true
  sudo ip link del veth-geo >/dev/null 2>&1 || true
  for ip in 198.51.100.20 203.0.113.20 175.139.0.20 198.18.0.20 10.9.9.20; do
    sudo ip route del "$ip/32" dev veth-geo >/dev/null 2>&1 || true
  done
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

if sudo docker inspect webtop-nginx >/dev/null 2>&1; then
  echo "webtop-nginx is already running; refusing to replace it" >&2
  exit 1
fi

# Docker's published-port proxy presents the bridge gateway, not the client.
sudo docker rm -f geo-peer >/dev/null 2>&1 || true
sudo docker run -d --name geo-peer -p 127.0.0.1:18444:9443 python:3.13-alpine \
  python -u -c 'import socket;s=socket.socket();s.bind(("0.0.0.0",9443));s.listen(1);c,a=s.accept();print("PEER",a[0],flush=True)' >/dev/null
sleep 0.4
python3 -c 'import socket;s=socket.create_connection(("127.0.0.1",18444),3);s.send(b"x");s.close()'
sleep 0.3
peer=$(sudo docker logs geo-peer 2>&1 | awk '/PEER/{print $2}')
echo "docker-proxy peer=$peer"
if [[ "$peer" != 172.* ]]; then
  echo "expected the published port to hide the client behind a 172.x gateway, got $peer" >&2
  exit 1
fi
sudo docker rm -f geo-peer >/dev/null

(cd "$ROOT/tests/geo" && go run . "$MMDB")
CERT_DIR="$WORKDIR/certs" "$ROOT/scripts/gen-certs.sh" init >/dev/null
CERT_DIR="$WORKDIR/certs" "$ROOT/scripts/gen-certs.sh" server --cn webtop.local --san DNS:webtop.local,IP:192.0.2.1 >/dev/null
SECRET=0123456789abcdef0123456789abcdef

# Bridge mode must refuse to start. A missing docker0 means the proxy bypass is possible.
set +e
# shellcheck disable=SC2024
sudo docker run --rm --name webtop-nginx \
  -e CERTADMIN_PROXY_SECRET="$SECRET" \
  -e ALLOWED_COUNTRIES=KR,JP \
  -e HTTPS_PORT=18443 \
  -e HTTP_PORT= \
  -e WEBTOP_UPSTREAM=127.0.0.1:9 \
  -e CERTADMIN_UPSTREAM=127.0.0.1:9 \
  -e REQUIRE_HOST_NETWORK=1 \
  -e GEOIP_WAIT_SECONDS=2 \
  -v "$MMDB:/usr/share/GeoIP/GeoLite2-Country.mmdb:ro" \
  -v "$WORKDIR/certs/ca/ca.crt:/etc/nginx/mtls/ca/ca.crt:ro" \
  -v "$WORKDIR/certs/server:/etc/nginx/mtls/server:ro" \
  -v "$WORKDIR/certs/crl:/etc/nginx/mtls/crl:ro" \
  -v "$LOGS:/var/log/nginx" \
  webtop-nginx:local >"$WORKDIR/bridge.out" 2>&1
bridge_rc=$?
set -e
echo "bridge start rc=$bridge_rc"
if ! grep -q 'REFUSING TO START' "$WORKDIR/bridge.out"; then
  echo '--- bridge output ---' >&2
  cat "$WORKDIR/bridge.out" >&2
  exit 1
fi
if [[ "$bridge_rc" -eq 0 ]]; then
  echo "bridge-mode nginx started" >&2
  exit 1
fi

sudo docker run -d --name webtop-nginx --network host \
  -e CERTADMIN_PROXY_SECRET="$SECRET" \
  -e ALLOWED_COUNTRIES=KR,JP \
  -e HTTPS_PORT=18443 \
  -e HTTP_PORT= \
  -e WEBTOP_UPSTREAM=127.0.0.1:9 \
  -e CERTADMIN_UPSTREAM=127.0.0.1:9 \
  -e REQUIRE_HOST_NETWORK=1 \
  -e GEOIP_WAIT_SECONDS=5 \
  -v "$MMDB:/usr/share/GeoIP/GeoLite2-Country.mmdb:ro" \
  -v "$WORKDIR/certs/ca/ca.crt:/etc/nginx/mtls/ca/ca.crt:ro" \
  -v "$WORKDIR/certs/server:/etc/nginx/mtls/server:ro" \
  -v "$WORKDIR/certs/crl:/etc/nginx/mtls/crl:ro" \
  -v "$LOGS:/var/log/nginx" \
  webtop-nginx:local >/dev/null

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if sudo docker logs webtop-nginx 2>&1 | grep -q 'geoip fail-closed'; then
    break
  fi
  sleep 0.3
done
sudo docker logs webtop-nginx 2>&1 | tail -30
sudo docker inspect -f '{{.State.Running}}' webtop-nginx | grep -q true

sudo ip netns del geo-test >/dev/null 2>&1 || true
sudo ip link del veth-geo >/dev/null 2>&1 || true
sudo ip netns add geo-test
sudo ip link add veth-geo type veth peer name veth-ns
sudo ip link set veth-ns netns geo-test
sudo ip addr add 192.0.2.1/24 dev veth-geo
sudo ip link set veth-geo up
sudo ip netns exec geo-test ip link set lo up
sudo ip netns exec geo-test ip addr add 192.0.2.20/24 dev veth-ns
sudo ip netns exec geo-test ip link set veth-ns up
for ip in 198.51.100.20 203.0.113.20 175.139.0.20 198.18.0.20 10.9.9.20; do
  sudo ip netns exec geo-test ip addr add "$ip/32" dev veth-ns
  sudo ip route replace "$ip/32" dev veth-geo
done
sudo sysctl -w net.ipv4.conf.veth-geo.rp_filter=0 >/dev/null
sudo ip netns exec geo-test ping -c 1 -W 2 192.0.2.1 >/dev/null

probe() {
  local src=$1
  local err="$WORKDIR/curl-$src.err"
  # shellcheck disable=SC2024
  sudo ip netns exec geo-test curl --interface "$src" -k -sv --max-time 5 \
    "https://192.0.2.1:18443/" -o /dev/null >"$err" 2>&1 || true
  if grep -q 'Server certificate' "$err"; then
    echo "$src TLS"
  else
    echo "$src DROP"
  fi
}

kr=$(probe 192.0.2.20)
jp=$(probe 198.51.100.20)
us=$(probe 203.0.113.20)
my=$(probe 175.139.0.20)
unknown=$(probe 198.18.0.20)
priv=$(probe 10.9.9.20)
echo "$kr"; echo "$jp"; echo "$us"; echo "$my"; echo "$unknown"; echo "$priv"
[[ "$kr" == "192.0.2.20 TLS" ]]
[[ "$jp" == "198.51.100.20 TLS" ]]
[[ "$us" == "203.0.113.20 DROP" ]]
[[ "$my" == "175.139.0.20 DROP" ]]
[[ "$unknown" == "198.18.0.20 DROP" ]]
[[ "$priv" == "10.9.9.20 TLS" ]]

sleep 2
log="$LOGS/stream.log"
grep -q 'client=175.139.0.20' "$log"
grep 'client=175.139.0.20' "$log" | grep -q 'country="MY"'
grep 'client=175.139.0.20' "$log" | grep -q 'allowed=0'
grep 'client=192.0.2.20' "$log" | grep -q 'country="KR"'
grep 'client=192.0.2.20' "$log" | grep -q 'allowed=1'
grep 'client=198.18.0.20' "$log" | grep -q 'allowed=0'
if grep -q 'client=172.17.0.1' "$log"; then
  echo "host-network nginx logged the docker gateway" >&2
  exit 1
fi

wrap="$WORKDIR/bin"
mkdir -p "$wrap"
cat > "$wrap/docker" <<'EOF'
#!/bin/sh
exec sudo docker "$@"
EOF
chmod 755 "$wrap/docker"
export PATH="$wrap:$PATH"
my_out=$(bash "$ROOT/webtop.sh" geo-test 175.139.0.1 2>&1) && {
  echo "geo-test allowed Malaysia: $my_out" >&2
  exit 1
}
echo "$my_out" | grep -q 'country MY'
echo "$my_out" | grep -q 'decision DROP'
kr_out=$(bash "$ROOT/webtop.sh" geo-test 192.0.2.20 2>&1)
echo "$kr_out" | grep -q 'country KR'
echo "$kr_out" | grep -q 'decision ALLOW'
status_out=$(bash "$ROOT/webtop.sh" geo-status 2>&1)
echo "$status_out" | grep -q '네트워크 모드: host'
echo "$status_out" | grep -q 'build_time='
echo "geo allow regression ok"
