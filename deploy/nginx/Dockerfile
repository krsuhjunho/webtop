FROM alpine:3.22

RUN apk add --no-cache \
      nginx \
      nginx-mod-http-geoip2 \
      nginx-mod-stream-geoip2 \
      libmaxminddb \
      tzdata \
      ca-certificates

COPY nginx.conf /etc/nginx/nginx.conf.template
COPY geoip-base.conf /etc/nginx/geoip-base.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

ENV ALLOWED_COUNTRIES=KR,JP \
    WEBTOP_UPSTREAM=127.0.0.1:33000 \
    CERTADMIN_UPSTREAM=127.0.0.1:18080 \
    REQUIRE_HOST_NETWORK=1 \
    TZ=Asia/Tokyo \
    GEOIP_DB=/usr/share/GeoIP/GeoLite2-Country.mmdb

EXPOSE 80 443
ENTRYPOINT ["/entrypoint.sh"]
