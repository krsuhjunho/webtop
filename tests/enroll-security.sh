#!/usr/bin/env bash
# Enrollment log redaction, one-time download, and default token lifetime.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'cleanup' EXIT

cleanup() {
  if [[ -n "${nginx_pid:-}" ]]; then
    kill "$nginx_pid" 2>/dev/null || true
    wait "$nginx_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The map in the shipped config is what access.log uses.
map_src=$(awk '
  $0 ~ /map \$request_uri \$logged_uri/ { capture = 1 }
  capture { print }
  capture && /^    }/ { exit }
' "$ROOT/deploy/nginx/nginx.conf")
[[ -n "$map_src" ]] || fail "logged_uri map missing"
grep -F -q "uri=\"\$logged_uri\"" "$ROOT/deploy/nginx/nginx.conf" || fail "access log still records request_uri"
grep -q 'error_log /var/log/nginx/error.log warn;' "$ROOT/deploy/nginx/nginx.conf"

port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
cat >"$tmp/nginx.conf" <<EOF
pid $tmp/nginx.pid;
error_log $tmp/nginx.err warn;
daemon on;
events { worker_connections 64; }
http {
    client_body_temp_path $tmp/body;
    proxy_temp_path $tmp/proxy;
    fastcgi_temp_path $tmp/fastcgi;
    uwsgi_temp_path $tmp/uwsgi;
    scgi_temp_path $tmp/scgi;
    log_format redacted '\$logged_uri';
    access_log $tmp/access.log redacted;
$map_src
    server {
        listen 127.0.0.1:${port};
        location / {
            return 200 "\$logged_uri\n";
        }
    }
}
EOF
nginx -t -c "$tmp/nginx.conf" >/tmp/nginx-t.out 2>&1 || {
  cat /tmp/nginx-t.out >&2
  fail "nginx -t failed"
}
nginx -c "$tmp/nginx.conf"
nginx_pid=$(cat "$tmp/nginx.pid")
for _ in 1 2 3 4 5 10; do
  curl -fsS "http://127.0.0.1:${port}/ready" >/dev/null 2>&1 && break
  sleep 0.1
done

check_uri() {
  local path=$1 expect=$2 got
  got=$(curl -fsS "http://127.0.0.1:${port}${path}")
  [[ "$got" == "$expect" ]] || fail "redaction ${path} -> ${got} wanted ${expect}"
  if [[ -f "$tmp/access.log" ]] && grep -q "$path" "$tmp/access.log"; then
    case "$path" in
      /enroll/supersecret|/enroll/dl/downloadsecret|/admin/dl/downloadsecret|/enroll/supersecret/ca.cer)
        fail "access log kept secret path ${path}"
        ;;
    esac
  fi
}
check_uri /enroll/supersecret /enroll/
check_uri '/enroll/supersecret?x=1' /enroll/
check_uri /enroll/supersecret/ca.cer /enroll/ca.cer
check_uri /enroll/supersecret/ca.crt /enroll/ca.crt
check_uri /enroll/dl/downloadsecret /enroll/dl/
check_uri /admin/dl/downloadsecret /admin/dl/
check_uri /fi/status /fi/status
if [[ -f "$tmp/access.log" ]]; then
  grep -q 'supersecret\|downloadsecret' "$tmp/access.log" && fail "sample log line contains a secret"
fi
kill "$nginx_pid"
wait "$nginx_pid" 2>/dev/null || true
nginx_pid=""

python3 - <<PY
import http.client
import importlib
import os
import sys
import threading
import time

sys.path.insert(0, "$ROOT/deploy/certadmin")
os.environ["CERT_DIR"] = "$tmp/certs"
os.environ["CERTADMIN_PROXY_SECRET"] = "a" * 32
os.environ["ENROLL_TTL_SECONDS"] = "180"
os.environ["LOG_PATH"] = "$tmp/certadmin.log"
import certadmin
importlib.reload(certadmin)

assert certadmin.default_ttl_seconds() == 180
os.environ["ENROLL_TTL_SECONDS"] = "15"
importlib.reload(certadmin)
assert certadmin.default_ttl_seconds() == 60
os.environ["ENROLL_TTL_SECONDS"] = "200000"
importlib.reload(certadmin)
assert certadmin.default_ttl_seconds() == 1440 * 60

os.environ["ENROLL_TTL_SECONDS"] = "180"
importlib.reload(certadmin)
certadmin.ensure_layout()
before = int(time.time())
assert certadmin.cli_enroll("phone", None) == 0
data = certadmin.load_tokens()
assert len(data) == 1
record = next(iter(data.values()))
delta = record["expires"] - before
assert 170 <= delta <= 190, delta

certadmin.PENDING.clear()
certadmin.stash(b"p12-bytes", "phone.p12")
item_id = next(iter(certadmin.PENDING))
results = []

def worker():
    results.append(certadmin.take_stash(item_id))

threads = [threading.Thread(target=worker) for _ in range(8)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
got = [item for item in results if item is not None]
assert len(got) == 1, results
assert got[0]["bytes"] == b"p12-bytes"
assert certadmin.take_stash(item_id) is None
assert item_id not in certadmin.PENDING

expired = "b" * 64
certadmin.save_tokens({
    expired: {"hash": expired, "expires": int(time.time()) - 5, "used": True, "name": "old"},
    record["hash"]: record,
})
kept = certadmin.load_tokens()
assert expired not in kept
assert record["hash"] in kept

token = certadmin.create_token("phone2", 180)
server = certadmin.ThreadingHTTPServer(("127.0.0.1", 0), certadmin.Handler)
port = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request("GET", "/enroll/" + token, headers={"X-Certadmin-Auth": "a" * 32})
    resp = conn.getresponse()
    body = resp.read()
    assert resp.status == 302, resp.status
    assert resp.getheader("Location") == "/enroll/"
    cookie = resp.getheader("Set-Cookie") or ""
    assert "HttpOnly" in cookie and "Secure" in cookie and "SameSite=Strict" in cookie
    assert token in cookie
    assert token.encode() not in body
    conn.request(
        "GET",
        "/enroll/",
        headers={"X-Certadmin-Auth": "a" * 32, "Cookie": cookie.split(";", 1)[0]},
    )
    page = conn.getresponse()
    page_body = page.read()
    assert page.status == 200, page.status
    assert token.encode() not in page_body, page_body[:500]
    assert b"action='/enroll/'" in page_body
finally:
    server.shutdown()
print("python ok")
PY

# Issuing removes the private key and does not leave a PKCS#12 unless --keep.
work=$(mktemp -d)
CERT_DIR="$work/certs" "$ROOT/scripts/gen-certs.sh" init >/dev/null
out="$work/laptop.p12"
CLIENT_P12_OUT="$out" CERT_DIR="$work/certs" "$ROOT/scripts/gen-certs.sh" client laptop >"$work/out.txt"
grep -q '^PKCS#12 password: ' "$work/out.txt"
[[ ! -e "$work/certs/clients/laptop.key" ]] || fail "client key was kept"
[[ ! -e "$work/certs/clients/laptop.p12" ]] || fail "client p12 was kept without --keep"
[[ -f "$work/certs/clients/laptop.crt" ]] || fail "client certificate missing"
[[ -f "$out" ]] || fail "p12 was not written for the operator"
stat -c '%a' "$out" | grep -q '600'
CERT_DIR="$work/certs" "$ROOT/scripts/gen-certs.sh" client other --keep >"$work/keep.txt" 2>&1
[[ ! -e "$work/certs/clients/other.key" ]] || fail "kept client still has a key"
[[ -f "$work/certs/clients/other.p12" ]] || fail "--keep did not write a p12"
stat -c '%a' "$work/certs/clients/other.p12" | grep -q '600'
grep -q 'WARNING: PKCS#12 private key remains' "$work/keep.txt"
if grep -q 'pass:\$' "$ROOT/scripts/gen-certs.sh"; then
  fail "pkcs12 password is still passed on the command line"
fi
grep -q 'env:P12_PASS' "$ROOT/scripts/gen-certs.sh"
if grep -q 'changeit' "$ROOT/scripts/gen-certs.sh"; then
  fail "changeit default remains"
fi
rm -rf "$work"

python3 -m py_compile "$ROOT/deploy/certadmin/certadmin.py" "$ROOT/deploy/certadmin/guide.py"
printf 'ok\n'
