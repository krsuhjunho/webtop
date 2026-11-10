#!/bin/sh
# Private CA, server certificate, client PKCS#12, and CRL for the mTLS proxy.
# Certificates stay under deploy/certs and are gitignored.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CERT_DIR=${CERT_DIR:-"$ROOT/deploy/certs"}
P12_PASS=${P12_PASS:-changeit}
DAYS_CA=${DAYS_CA:-3650}
DAYS_CERT=${DAYS_CERT:-825}

umask 077

usage() {
  cat <<'EOF'
Usage: scripts/gen-certs.sh <command> [options]

Commands:
  init                         Create the CA and an empty CRL (idempotent)
  server [--cn NAME] [--san LIST]
                               Issue the Nginx server certificate
  client <name>                Issue a client cert and <name>.p12
  revoke <name>                Revoke a client cert and regenerate the CRL
  crl                          Regenerate the CRL from the CA database

Options:
  --cn NAME                    Server common name (default webtop.local)
  --san LIST                   Comma-separated subjectAltName values
                               (default DNS:webtop.local,DNS:localhost,IP:127.0.0.1)
  --p12-pass PASS              PKCS#12 password (default changeit, or $P12_PASS)

After revoke or crl, reload Nginx so it re-reads the CRL:
  docker compose -f deploy/docker-compose.yml exec nginx nginx -s reload

The CRL is rewritten in place. Do not delete deploy/certs/crl/ca.crl while
Nginx is running; a replaced inode can leave the container on the old file.
EOF
}

need_openssl() {
  command -v openssl >/dev/null 2>&1 || {
    echo "openssl is required" >&2
    exit 1
  }
}

write_cnf() {
  cat > "$CERT_DIR/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${CERT_DIR}
certs             = \$dir
new_certs_dir     = \$dir/issued
database          = \$dir/index.txt
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
certificate       = \$dir/ca/ca.crt
private_key       = \$dir/ca/ca.key
default_md        = sha256
default_days      = ${DAYS_CERT}
default_crl_days  = ${DAYS_CA}
preserve          = no
policy            = policy_loose
unique_subject    = no

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
distinguished_name = dn
string_mask        = utf8only
default_md         = sha256
prompt             = no

[ dn ]
CN = Webtop CA

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF
}

ensure_layout() {
  mkdir -p "$CERT_DIR/ca" "$CERT_DIR/server" "$CERT_DIR/clients" "$CERT_DIR/crl" "$CERT_DIR/issued"
  [ -f "$CERT_DIR/index.txt" ] || : > "$CERT_DIR/index.txt"
  [ -f "$CERT_DIR/index.txt.attr" ] || echo 'unique_subject = no' > "$CERT_DIR/index.txt.attr"
  [ -f "$CERT_DIR/serial" ] || echo 1000 > "$CERT_DIR/serial"
  [ -f "$CERT_DIR/crlnumber" ] || echo 1000 > "$CERT_DIR/crlnumber"
  write_cnf
}

pem_only() {
  src=$1
  tmp=$(mktemp)
  openssl x509 -in "$src" -out "$tmp"
  cat "$tmp" > "$src"
  rm -f "$tmp"
}

cmd_init() {
  ensure_layout
  if [ -f "$CERT_DIR/ca/ca.key" ] && [ -f "$CERT_DIR/ca/ca.crt" ]; then
    echo "CA already exists: $CERT_DIR/ca/ca.crt"
  else
    openssl req -x509 -new -nodes \
      -newkey rsa:2048 \
      -keyout "$CERT_DIR/ca/ca.key" \
      -out "$CERT_DIR/ca/ca.crt" \
      -days "$DAYS_CA" \
      -config "$CERT_DIR/openssl.cnf" \
      -extensions v3_ca \
      -subj "/CN=Webtop CA/O=Webtop"
    chmod 600 "$CERT_DIR/ca/ca.key"
    echo "Created CA: $CERT_DIR/ca/ca.crt"
  fi
  cmd_crl
}

cmd_crl() {
  ensure_layout
  [ -f "$CERT_DIR/ca/ca.crt" ] || { echo "run init first" >&2; exit 1; }
  openssl ca -config "$CERT_DIR/openssl.cnf" -gencrl -out "$CERT_DIR/crl/ca.crl"
  echo "Wrote CRL: $CERT_DIR/crl/ca.crl"
}

valid_name() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]{1,64}$'
}

cmd_server() {
  cn=webtop.local
  san="DNS:webtop.local,DNS:localhost,IP:127.0.0.1"
  while [ $# -gt 0 ]; do
    case $1 in
      --cn) cn=$2; shift 2 ;;
      --san) san=$2; shift 2 ;;
      *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done
  ensure_layout
  [ -f "$CERT_DIR/ca/ca.crt" ] || { echo "run init first" >&2; exit 1; }
  if [ -f "$CERT_DIR/server/server.crt" ]; then
    echo "Server certificate already exists: $CERT_DIR/server/server.crt" >&2
    echo "Remove it first if you want to reissue." >&2
    exit 1
  fi
  ext=$(mktemp)
  cat > "$ext" <<EOF
[server_ext]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${san}
EOF
  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$CERT_DIR/server/server.key" \
    -out "$CERT_DIR/server/server.csr" \
    -subj "/CN=${cn}/O=Webtop"
  openssl ca -batch -config "$CERT_DIR/openssl.cnf" \
    -in "$CERT_DIR/server/server.csr" \
    -out "$CERT_DIR/server/server.crt" \
    -extfile "$ext" -extensions server_ext
  pem_only "$CERT_DIR/server/server.crt"
  rm -f "$ext" "$CERT_DIR/server/server.csr"
  chmod 600 "$CERT_DIR/server/server.key"
  echo "Wrote $CERT_DIR/server/server.crt (CN=${cn})"
}

cmd_client() {
  name=${1:-}
  [ -n "$name" ] || { usage; exit 1; }
  shift || true
  while [ $# -gt 0 ]; do
    case $1 in
      --p12-pass) P12_PASS=$2; shift 2 ;;
      *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done
  valid_name "$name" || { echo "invalid client name: $name" >&2; exit 1; }
  ensure_layout
  [ -f "$CERT_DIR/ca/ca.crt" ] || { echo "run init first" >&2; exit 1; }
  if [ -f "$CERT_DIR/clients/${name}.crt" ]; then
    echo "Client already exists: $name" >&2
    echo "Revoke it before issuing the same name again." >&2
    exit 1
  fi
  ext=$(mktemp)
  cat > "$ext" <<'EOF'
[client_ext]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF
  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$CERT_DIR/clients/${name}.key" \
    -out "$CERT_DIR/clients/${name}.csr" \
    -subj "/CN=${name}/O=Webtop"
  openssl ca -batch -config "$CERT_DIR/openssl.cnf" \
    -in "$CERT_DIR/clients/${name}.csr" \
    -out "$CERT_DIR/clients/${name}.crt" \
    -extfile "$ext" -extensions client_ext
  pem_only "$CERT_DIR/clients/${name}.crt"
  openssl pkcs12 -export \
    -inkey "$CERT_DIR/clients/${name}.key" \
    -in "$CERT_DIR/clients/${name}.crt" \
    -certfile "$CERT_DIR/ca/ca.crt" \
    -name "$name" \
    -out "$CERT_DIR/clients/${name}.p12" \
    -passout "pass:${P12_PASS}"
  rm -f "$ext" "$CERT_DIR/clients/${name}.csr"
  chmod 600 "$CERT_DIR/clients/${name}.key" "$CERT_DIR/clients/${name}.p12"
  echo "Wrote $CERT_DIR/clients/${name}.p12"
  echo "PKCS#12 password: ${P12_PASS}"
}

cmd_revoke() {
  name=${1:-}
  [ -n "$name" ] || { usage; exit 1; }
  valid_name "$name" || { echo "invalid client name: $name" >&2; exit 1; }
  ensure_layout
  crt="$CERT_DIR/clients/${name}.crt"
  [ -f "$crt" ] || { echo "no certificate for ${name}" >&2; exit 1; }
  openssl ca -config "$CERT_DIR/openssl.cnf" -revoke "$crt" -crl_reason keyCompromise
  cmd_crl
  echo "Revoked ${name}. Reload Nginx to apply the CRL."
}

need_openssl
cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 1; }
shift
case $cmd in
  init) cmd_init "$@" ;;
  server) cmd_server "$@" ;;
  client) cmd_client "$@" ;;
  revoke) cmd_revoke "$@" ;;
  crl) cmd_crl "$@" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
