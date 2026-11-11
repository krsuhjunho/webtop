#!/bin/sh
# Private CA, server certificate, client PKCS#12, and CRL for the mTLS proxy.
# Certificates stay under deploy/certs and are gitignored.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CERT_DIR=${CERT_DIR:-"$ROOT/deploy/certs"}
P12_PASS=${P12_PASS:-}
DAYS_CA=${DAYS_CA:-3650}
DAYS_CERT=${DAYS_CERT:-825}

umask 077

usage() {
  cat <<'EOF'
Usage: scripts/gen-certs.sh <command> [options]

Commands:
  init [--name-constraint NAME]
                               Create the CA and an empty CRL (idempotent)
                               Repeat --name-constraint for each permitted DNS
                               name or IP. A new CA then carries critical
                               nameConstraints. An existing CA is left as-is.
  server [--cn NAME] [--san LIST]
                               Issue the Nginx server certificate
  client <name> [--admin] [--days N] [--keep]
                               Issue a client cert. The private key is not kept.
                               Without --keep, the PKCS#12 is written to
                               $CLIENT_P12_OUT (required) and the password is
                               printed once. --keep stores clients/<name>.p12
                               mode 0600 and leaves that copy on the server.
                               --admin sets OU=admin so Nginx allows /admin/
  revoke <name>                Revoke a client cert and regenerate the CRL
  crl                          Regenerate the CRL from the CA database

Options:
  --cn NAME                    Server common name (default webtop.local)
  --san LIST                   Comma-separated subjectAltName values
                               (default DNS:webtop.local,DNS:localhost,IP:127.0.0.1)
  --p12-pass PASS              PKCS#12 password. Prefer a prompt or an empty
                               P12_PASS so a random password is generated.
                               --p12-pass is visible in shell history.
  --admin                      Mark the client certificate OU=admin
  --days N                     Certificate lifetime in days (default 825)
  --name-constraint NAME       Permitted DNS name or IP for a new CA.
                               Repeat the flag. DNS permits that name and its
                               subdomains. IP may be a single address or CIDR.

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
  nc_line=""
  if [ -n "${1:-}" ]; then
    nc_line="nameConstraints = critical,${1}"
  fi
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
${nc_line}
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

ipv4_ok() {
  printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
  oldifs=$IFS
  IFS=.
  # shellcheck disable=SC2086
  set -- $1
  IFS=$oldifs
  [ "$#" -eq 4 ] || return 1
  for octet in "$@"; do
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
}

ipv4_mask() {
  prefix=$1
  bits=$prefix
  out=""
  i=0
  while [ "$i" -lt 4 ]; do
    if [ "$bits" -ge 8 ]; then
      octet=255
      bits=$((bits - 8))
    elif [ "$bits" -gt 0 ]; then
      octet=$(( (255 << (8 - bits)) & 255 ))
      bits=0
    else
      octet=0
    fi
    if [ -n "$out" ]; then
      out="${out}.${octet}"
    else
      out=$octet
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

ipv6_mask() {
  prefix=$1
  bits=$prefix
  out=""
  i=0
  while [ "$i" -lt 8 ]; do
    if [ "$bits" -ge 16 ]; then
      group=ffff
      bits=$((bits - 16))
    elif [ "$bits" -gt 0 ]; then
      group=$(printf '%x' $(( (65535 << (16 - bits)) & 65535 )))
      bits=0
    else
      group=0
    fi
    if [ -n "$out" ]; then
      out="${out}:${group}"
    else
      out=$group
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

dns_constraint() {
  name=$1
  name=${name#DNS:}
  name=${name#dns:}
  name=${name%.}
  name=${name#\*.}
  printf '%s' "$name" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$' || return 1
  [ "${#name}" -le 253 ] || return 1
  printf 'permitted;DNS:%s' "$name"
}

ip_constraint() {
  raw=$1
  raw=${raw#IP:}
  raw=${raw#ip:}
  host=${raw%%/*}
  prefix=""
  case $raw in
    */*) prefix=${raw#*/} ;;
  esac
  if printf '%s' "$host" | grep -q ':'; then
    printf '%s' "$host" | grep -Eq '^[0-9A-Fa-f:.]+$' || return 1
    if [ -z "$prefix" ]; then
      prefix=128
    fi
    printf '%s' "$prefix" | grep -Eq '^(0|[1-9][0-9]?|1[0-1][0-9]|12[0-8])$' || return 1
    printf 'permitted;IP:%s/%s' "$host" "$(ipv6_mask "$prefix")"
    return 0
  fi
  ipv4_ok "$host" || return 1
  if [ -z "$prefix" ]; then
    prefix=32
  fi
  printf '%s' "$prefix" | grep -Eq '^([0-9]|[12][0-9]|3[0-2])$' || return 1
  printf 'permitted;IP:%s/%s' "$host" "$(ipv4_mask "$prefix")"
}

append_constraint() {
  piece=$1
  if [ -z "$NAME_CONSTRAINTS" ]; then
    NAME_CONSTRAINTS=$piece
  else
    NAME_CONSTRAINTS="${NAME_CONSTRAINTS},${piece}"
  fi
}

cmd_init() {
  NAME_CONSTRAINTS=""
  while [ $# -gt 0 ]; do
    case $1 in
      --name-constraint)
        [ $# -ge 2 ] || { echo "missing value for --name-constraint" >&2; exit 1; }
        value=$2
        shift 2
        piece=""
        case $value in
          [Dd][Nn][Ss]:*)
            piece=$(dns_constraint "$value") || { echo "invalid DNS constraint: $value" >&2; exit 1; }
            ;;
          *)
            if printf '%s' "$value" | grep -Eq '^[Ii][Pp]:' \
              || printf '%s' "$value" | grep -q ':' \
              || printf '%s' "${value%%/*}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
              piece=$(ip_constraint "$value") || { echo "invalid IP constraint: $value" >&2; exit 1; }
            else
              piece=$(dns_constraint "$value") || { echo "invalid DNS constraint: $value" >&2; exit 1; }
            fi
            ;;
        esac
        append_constraint "$piece"
        ;;
      *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done
  if [ -f "$CERT_DIR/ca/ca.key" ] && [ -f "$CERT_DIR/ca/ca.crt" ]; then
    if [ -n "$NAME_CONSTRAINTS" ]; then
      echo "CA already exists: $CERT_DIR/ca/ca.crt" >&2
      echo "Name constraints are fixed inside that CA certificate." >&2
      echo "Replacing the CA means reissuing the server certificate and every client certificate, then installing the new root on each device." >&2
      exit 1
    fi
    ensure_layout
    echo "CA already exists: $CERT_DIR/ca/ca.crt"
    cmd_crl
    return 0
  fi
  ensure_layout
  if [ -n "$NAME_CONSTRAINTS" ]; then
    write_cnf "$NAME_CONSTRAINTS"
  fi
  openssl req -x509 -new -nodes \
    -newkey rsa:2048 \
    -keyout "$CERT_DIR/ca/ca.key" \
    -out "$CERT_DIR/ca/ca.crt" \
    -days "$DAYS_CA" \
    -config "$CERT_DIR/openssl.cnf" \
    -extensions v3_ca \
    -subj "/CN=Webtop CA/O=Webtop"
  chmod 600 "$CERT_DIR/ca/ca.key"
  if [ -n "$NAME_CONSTRAINTS" ]; then
    echo "Created CA with name constraints: $CERT_DIR/ca/ca.crt"
  else
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
  admin=0
  keep=0
  days=$DAYS_CERT
  while [ $# -gt 0 ]; do
    case $1 in
      --p12-pass) P12_PASS=$2; shift 2 ;;
      --admin) admin=1; shift ;;
      --keep) keep=1; shift ;;
      --days) days=$2; shift 2 ;;
      *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done
  valid_name "$name" || { echo "invalid client name: $name" >&2; exit 1; }
  printf '%s' "$days" | grep -Eq '^[0-9]+$' || { echo "invalid days" >&2; exit 1; }
  ensure_layout
  [ -f "$CERT_DIR/ca/ca.crt" ] || { echo "run init first" >&2; exit 1; }
  if [ -f "$CERT_DIR/clients/${name}.crt" ]; then
    echo "Client already exists: $name" >&2
    echo "Revoke it before issuing the same name again." >&2
    exit 1
  fi
  ext=$(mktemp)
  tmp_p12=""
  trap 'rm -f "$ext" "$CERT_DIR/clients/${name}.csr" "$CERT_DIR/clients/${name}.key" ${tmp_p12:+"$tmp_p12"}' EXIT
  cat > "$ext" <<'EOF'
[client_ext]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF
  if [ "$admin" -eq 1 ]; then
    subject="/CN=${name}/OU=admin/O=Webtop"
  else
    subject="/CN=${name}/O=Webtop"
  fi
  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$CERT_DIR/clients/${name}.key" \
    -out "$CERT_DIR/clients/${name}.csr" \
    -subj "$subject"
  openssl ca -batch -config "$CERT_DIR/openssl.cnf" \
    -in "$CERT_DIR/clients/${name}.csr" \
    -out "$CERT_DIR/clients/${name}.crt" \
    -days "$days" \
    -extfile "$ext" -extensions client_ext
  pem_only "$CERT_DIR/clients/${name}.crt"
  if [ -z "$P12_PASS" ]; then
    P12_PASS=$(openssl rand -hex 16)
  fi
  export P12_PASS
  tmp_p12=$(mktemp)
  openssl pkcs12 -export \
    -inkey "$CERT_DIR/clients/${name}.key" \
    -in "$CERT_DIR/clients/${name}.crt" \
    -certfile "$CERT_DIR/ca/ca.crt" \
    -name "$name" \
    -out "$tmp_p12" \
    -passout env:P12_PASS
  rm -f "$ext" "$CERT_DIR/clients/${name}.csr" "$CERT_DIR/clients/${name}.key"
  if [ "$keep" -eq 1 ]; then
    mv "$tmp_p12" "$CERT_DIR/clients/${name}.p12"
    chmod 600 "$CERT_DIR/clients/${name}.p12"
    echo "WARNING: PKCS#12 private key remains on the server: $CERT_DIR/clients/${name}.p12" >&2
    echo "Wrote $CERT_DIR/clients/${name}.p12"
  else
    [ -n "${CLIENT_P12_OUT:-}" ] || {
      rm -f "$tmp_p12"
      echo "CLIENT_P12_OUT is required unless --keep is set" >&2
      exit 1
    }
    mv "$tmp_p12" "$CLIENT_P12_OUT"
    chmod 600 "$CLIENT_P12_OUT"
    echo "Wrote $CLIENT_P12_OUT"
    echo "The server did not keep the private key. Move this file off the host and delete it." >&2
  fi
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
