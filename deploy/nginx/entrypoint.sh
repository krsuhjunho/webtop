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

countries="${ALLOWED_COUNTRIES:-KR,JP}"
{
  echo "map \$geoip2_country_code \$country_allowed {"
  echo "    default 0;"
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
if [ "$https_port" = "443" ]; then
  # shellcheck disable=SC2016 # nginx sees $host, not the shell.
  redir='return 301 https://$host$request_uri;'
else
  redir="return 301 https://\$host:${https_port}\$request_uri;"
fi

sed \
  -e "s#__WEBTOP_UPSTREAM__#${upstream}#g" \
  -e "s#__RESOLVER__#${resolver}#g" \
  -e "s#__HTTPS_REDIRECT__#${redir}#g" \
  /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

if [ "$#" -eq 0 ]; then
  set -- nginx -g 'daemon off;'
fi
exec "$@"
