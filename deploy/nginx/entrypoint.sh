#!/bin/sh
# Render country allow-list and upstream, then start nginx.
set -eu

DB="${GEOIP_DB:-/usr/share/GeoIP/GeoLite2-Country.mmdb}"
WAIT="${GEOIP_WAIT_SECONDS:-180}"
i=0
while [ ! -s "$DB" ]; do
  i=$((i + 1))
  if [ "$i" -gt "$WAIT" ]; then
    echo "GeoLite2 database not found at ${DB}." >&2
    echo "Set MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY for the geoipupdate service." >&2
    exit 1
  fi
  sleep 1
done

# Exit 6 means the IP is absent. That is a readable database.
# set -e would otherwise abort on that lookup. Any other failure refuses to start.
mmdb_rc=0
mmdblookup --file "$DB" --ip 127.0.0.1 >/tmp/mmdblookup.out 2>&1 || mmdb_rc=$?
if [ "$mmdb_rc" -ne 0 ] && [ "$mmdb_rc" -ne 6 ]; then
  cat /tmp/mmdblookup.out >&2
  echo "GeoLite2 database is not readable: ${DB}" >&2
  exit 1
fi

countries="${ALLOWED_COUNTRIES:-KR,JP}"
{
  echo "map \$geoip2_country_code \$country_allowed {"
  echo "    default 0;"
  echo "    \"\" 0;"
  echo "    \"-\" 0;"
  # shellcheck disable=SC2086
  oldifs=$IFS
  IFS=', '
  for raw in $countries; do
    code=$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')
    [ -n "$code" ] || continue
    printf '%s' "$code" | grep -Eq '^[A-Z]{2}$' || {
      echo "ALLOWED_COUNTRIES has invalid code: ${code}" >&2
      exit 1
    }
    echo "    ${code} 1;"
  done
  IFS=$oldifs
  echo "}"
} > /etc/nginx/country-allow.conf

upstream="${WEBTOP_UPSTREAM:-webtop:3000}"
printf '%s' "$upstream" | grep -Eq '^[A-Za-z0-9._:-]+$' || {
  echo "WEBTOP_UPSTREAM is invalid: ${upstream}" >&2
  exit 1
}

# Variable proxy_pass needs a resolver. Compose uses Docker's DNS.
# Override NGINX_RESOLVER when the proxy is not on a compose network.
resolver="resolver ${NGINX_RESOLVER:-127.0.0.11} valid=10s ipv6=off;"

https_port="${HTTPS_PORT:-443}"
printf '%s' "$https_port" | grep -Eq '^[0-9]+$' || {
  echo "HTTPS_PORT is invalid: ${https_port}" >&2
  exit 1
}
if [ "$https_port" -lt 1 ] || [ "$https_port" -gt 65535 ]; then
  echo "HTTPS_PORT is out of range: ${https_port}" >&2
  exit 1
fi

http_port="${HTTP_PORT:-}"
if [ -n "$http_port" ]; then
  printf '%s' "$http_port" | grep -Eq '^[0-9]+$' || {
    echo "HTTP_PORT is invalid: ${http_port}" >&2
    exit 1
  }
  if [ "$http_port" = "$https_port" ]; then
    echo "HTTP_PORT and HTTPS_PORT must differ" >&2
    exit 1
  fi
fi

if [ "$https_port" = "443" ]; then
  # shellcheck disable=SC2016 # nginx sees $host, not the shell.
  redir='return 301 https://$host$request_uri;'
else
  redir="return 301 https://\$host:${https_port}\$request_uri;"
fi

secret="${CERTADMIN_PROXY_SECRET:-}"
printf '%s' "$secret" | grep -Eq '^[A-Za-z0-9]{16,128}$' || {
  echo "CERTADMIN_PROXY_SECRET must be 16-128 letters or digits" >&2
  exit 1
}

{
  echo "map \$ssl_client_cn \$cn_is_admin {"
  echo "    default 0;"
  oldifs=$IFS
  IFS=', '
  for raw in ${ADMIN_CNS:-}; do
    cn=$(printf '%s' "$raw" | tr -d ' ')
    [ -n "$cn" ] || continue
    printf '%s' "$cn" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || {
      echo "ADMIN_CNS has invalid name: ${cn}" >&2
      exit 1
    }
    echo "    ${cn} 1;"
  done
  IFS=$oldifs
  echo "}"
} > /etc/nginx/admin-cn.conf

bytes=$(wc -c < "$DB" | tr -d ' ')
echo "geoip fail-closed: allow=${countries} db=${DB} bytes=${bytes} http_port=${http_port:-disabled} upstream=${upstream}" >&2
echo "geoip: empty or unknown country is denied. A VPN location name can differ from this database." >&2

sed \
  -e "s#__WEBTOP_UPSTREAM__#${upstream}#g" \
  -e "s#__RESOLVER__#${resolver}#g" \
  -e "s#__HTTPS_REDIRECT__#${redir}#g" \
  -e "s#__CERTADMIN_SECRET__#${secret}#g" \
  -e "s#__HTTP_PORT__#${http_port:-80}#g" \
  /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

if [ -z "$http_port" ]; then
  sed -i '/# HTTP_SERVER_BEGIN/,/# HTTP_SERVER_END/d' /etc/nginx/nginx.conf
fi

nginx -t >/tmp/nginx-t.err 2>&1 || {
  cat /tmp/nginx-t.err >&2
  exit 1
}

watch_crl() {
  last=0
  while true; do
    if [ -f /etc/nginx/mtls/crl/ca.crl ]; then
      now=$(stat -c %Y /etc/nginx/mtls/crl/ca.crl 2>/dev/null || echo 0)
      if [ "$last" != "0" ] && [ "$now" != "$last" ]; then
        nginx -s reload || true
      fi
      last=$now
    fi
    sleep 1
  done
}
watch_crl &

if [ "$#" -eq 0 ]; then
  set -- nginx -g 'daemon off;'
fi
exec "$@"
