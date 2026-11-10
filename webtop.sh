#!/usr/bin/env bash
# Interactive and non-interactive lifecycle for the webtop mTLS stack.
# Secrets are never printed. Failures return to the menu instead of exiting.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_EXAMPLE="$ROOT/deploy/.env.example"
ENV_FILE="$ROOT/deploy/.env"
COMPOSE_FILE="$ROOT/deploy/docker-compose.yml"
CERT_DIR="$ROOT/deploy/certs"
GEN_CERTS="$ROOT/scripts/gen-certs.sh"
ACCESS_LOG="$ROOT/deploy/logs/access.log"
COMPOSE_HTTP="$ROOT/deploy/compose.http.yml"
UPDATE_LOG="$ROOT/deploy/logs/update.log"
UPDATE_LOCK="$ROOT/deploy/logs/update.lock"
IMAGE_REF="ghcr.io/krsuhjunho/webtop:latest"
CRONTAB=${CRONTAB:-crontab}

NONINTERACTIVE=0
OPT_YES=0
OPT_PRUNE=0
OPT_HTTP_SET=0
OPT_CN=""
OPT_EXTRA=""
OPT_NAME=""
OPT_P12=""
OPT_ACCOUNT=""
OPT_LICENSE=""
OPT_COUNTRIES=""
OPT_PUID=""
OPT_PGID=""
OPT_TZ=""
OPT_SERVICE=""
OPT_HTTPS=""
OPT_HTTP=""
OPT_SCHEDULE=""
OPT_MODE=""

if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_CYAN=$'\033[1;36m'
  C_OFF=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  C_OFF=""
fi

info() { printf '%s\n' "$*"; }
ok() { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
err() { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF" >&2; }

on_int() {
  printf '\n'
}

trap on_int INT

pause() {
  [[ "$NONINTERACTIVE" -eq 1 || ! -t 0 ]] && return 0
  local _unused
  read -r -p "Enter를 누르면 메뉴로 " _unused || true
}

prompt() {
  local label=$1 default=$2 reply
  if [[ "$NONINTERACTIVE" -eq 1 || ! -t 0 ]]; then
    printf '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${label} [${default}]: " reply || true
    printf '%s' "${reply:-$default}"
  else
    read -r -p "${label}: " reply || true
    printf '%s' "$reply"
  fi
}

prompt_secret() {
  local __name=$1 label=$2 value confirm
  if [[ "$NONINTERACTIVE" -eq 1 || ! -t 0 ]]; then
    err "비밀번호는 대화형 모드에서만 묻습니다. --p12-pass 또는 P12_PASS 를 사용하세요."
    return 1
  fi
  while true; do
    read -r -s -p "${label}: " value || true
    printf '\n'
    read -r -s -p "다시 입력: " confirm || true
    printf '\n'
    if [[ -n "$value" && "$value" == "$confirm" ]]; then
      printf -v "$__name" '%s' "$value"
      return 0
    fi
    err "비밀번호가 비었거나 서로 다릅니다."
  done
}

usage() {
  cat <<'EOF'
사용법: ./webtop.sh [명령] [옵션]

인자 없이 실행하면 번호 메뉴가 나옵니다.

명령:
  precheck              사전 점검
  env                   deploy/.env 작성 또는 수정
  ca                    CA 생성
  server                서버 인증서 발급
  client <이름>         클라이언트 인증서 발급
  list                  클라이언트 인증서 목록
  revoke <이름>         클라이언트 인증서 폐기 후 Nginx 리로드
  start                 스택 시작
  stop                  스택 중지
  restart               스택 재시작
  status                상태
  logs <서비스>         로그 (비대화형이면 최근 100줄)
  access                접속 로그
  update                새 버전이 있을 때만 이미지 업데이트
  check-update          업데이트 확인만
  auto-update           cron 용. UPDATE_MODE 에 따라 확인 또는 적용
  cron-install          주간 cron 등록
  cron-remove           주간 cron 제거
  cron-status           주간 cron 상태
  install               전체 자동 설치

옵션:
  --account ID          MaxMind 계정 ID
  --license KEY         MaxMind 라이선스 키 (프로세스 목록에 보일 수 있음)
  --countries KR,JP
  --puid N  --pgid N  --tz Asia/Tokyo
  --https-port N        외부 HTTPS 포트 (기본 443)
  --http-port N|none    HTTP 리다이렉트 포트. none 이면 끔
  --cn 도메인  --extra name,ip
  --name 장치  --p12-pass 비밀번호
  --service webtop|nginx|geoipupdate
  --yes                 업데이트 확인 질문을 생략
  --prune               적용 후 이전 dangling 이미지 삭제
  --schedule '0 6 * * 1'
  --mode check|apply
EOF
}

have() {
  command -v "$1" >/dev/null 2>&1
}

port_listening() {
  local port=$1 hex
  hex=$(printf '%04X' "$port")
  awk -v h="$hex" '
    FNR == 1 { next }
    {
      split($2, a, ":")
      if (toupper(a[2]) == h && $4 == "0A") found = 1
    }
    END { exit !found }
  ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

stack_nginx_running() {
  have docker || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'webtop-nginx'
}

compose() {
  local -a args
  local http
  args=(--env-file "$ENV_FILE" -f "$COMPOSE_FILE")
  http=$(env_get HTTP_PORT)
  if [[ -n "$http" ]]; then
    args+=(-f "$COMPOSE_HTTP")
  fi
  docker compose "${args[@]}" "$@"
}

https_port_configured() {
  local port
  port=$(env_get HTTPS_PORT)
  printf '%s' "${port:-443}"
}

http_port_configured() {
  if [[ -f "$ENV_FILE" ]] && grep -qE '^HTTP_PORT=' "$ENV_FILE"; then
    env_get HTTP_PORT
    return 0
  fi
  printf '80'
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  ((10#$1 >= 1 && 10#$1 <= 65535))
}

port_is_ours() {
  local port=$1 https http
  stack_nginx_running || return 1
  https=$(https_port_configured)
  http=$(http_port_configured)
  [[ "$port" == "$https" || ( -n "$http" && "$port" == "$http" ) ]]
}

port_holders() {
  local port=$1 shown=0 line
  if have ss; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      info "    ss: ${line}"
      shown=1
    done < <(ss -H -ltnp "sport = :${port}" 2>/dev/null || true)
  fi
  if have lsof; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      info "    lsof: ${line}"
      shown=1
    done < <(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print}')
  fi
  if [[ "$shown" -eq 0 ]]; then
    warn "    프로세스 이름은 보이지 않습니다. ss 또는 lsof 를 권한 있게 실행하세요."
  fi
}

describe_port() {
  local port=$1
  if port_listening "$port"; then
    if port_is_ours "$port"; then
      warn "포트 ${port}: 사용 중 (이 스택의 webtop-nginx)"
    else
      err "포트 ${port}: 사용 중"
    fi
    port_holders "$port"
    return 0
  fi
  ok "포트 ${port}: 사용 가능"
}

normalize_http_port() {
  local value=$1
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  if [[ -z "$value" || "$value" == "none" || "$value" == "off" || "$value" == "-" ]]; then
    printf ''
    return 0
  fi
  printf '%s' "$value"
}

require_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    err "deploy/.env 가 없습니다. 먼저 초기 설정을 실행하세요."
    return 1
  fi
  return 0
}

env_get() {
  local key=$1
  local line
  [[ -f "$ENV_FILE" ]] || return 0
  line=$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)
  printf '%s' "${line#"${key}"=}"
}

env_set() {
  local key=$1 value=$2 tmp
  if [[ "$value" == *$'\n'* ]]; then
    err "${key} 값에 줄바꿈이 있습니다."
    return 1
  fi
  tmp=$(mktemp "${ENV_FILE}.XXXXXX")
  KEY="$key" VAL="$value" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"]; found = 0 }
    index($0, k "=") == 1 { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "$ENV_FILE" >"$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

valid_countries() {
  local value=$1
  [[ "$value" =~ ^[A-Z]{2}(,[A-Z]{2})*$ ]]
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

valid_cn() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]
}

build_san() {
  local cn=$1 extra=$2 san item
  san="DNS:${cn},DNS:localhost,IP:127.0.0.1"
  IFS=',' read -r -a parts <<<"$extra"
  for item in "${parts[@]}"; do
    item=${item//[[:space:]]/}
    [[ -z "$item" ]] && continue
    if [[ "$item" == DNS:* || "$item" == IP:* ]]; then
      san+=",${item}"
    elif [[ "$item" == *:* || "$item" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
      san+=",IP:${item}"
    else
      san+=",DNS:${item}"
    fi
  done
  printf '%s' "$san"
}

fmt_openssl_date() {
  local raw=$1 yy year
  raw=${raw%%Z*}
  raw=${raw%%,*}
  [[ ${#raw} -ge 6 ]] || { printf '%s' "$1"; return; }
  yy=${raw:0:2}
  if ((10#$yy >= 70)); then
    year=$((1900 + 10#$yy))
  else
    year=$((2000 + 10#$yy))
  fi
  printf '%04d-%s-%s' "$year" "${raw:2:2}" "${raw:4:2}"
}

cmd_precheck_ports() {
  local https http problem=0
  https=$(https_port_configured)
  http=$(http_port_configured)
  info "사용할 포트"
  describe_port "$https"
  if port_listening "$https" && ! port_is_ours "$https"; then
    problem=1
  fi
  if [[ -n "$http" ]]; then
    describe_port "$http"
    if port_listening "$http" && ! port_is_ours "$http"; then
      problem=1
    fi
  else
    info "HTTP 리다이렉트: 끔"
  fi
  [[ "$problem" -eq 0 ]]
}

cmd_precheck() {
  local missing=0 name port_problem=0 ver
  info "도구 확인"
  for name in docker openssl git; do
    if have "$name"; then
      case "$name" in
        openssl) ver=$(openssl version 2>&1 | head -n 1) ;;
        *) ver=$("$name" --version 2>&1 | head -n 1) ;;
      esac
      ok "  있음  ${name} (${ver})"
    else
      err "  없음  $name"
      missing=1
    fi
  done
  if docker compose version >/dev/null 2>&1; then
    ok "  있음  docker compose ($(docker compose version --short 2>/dev/null || docker compose version | head -n 1))"
  else
    err "  없음  docker compose"
    missing=1
  fi

  cmd_precheck_ports || port_problem=1

  if stack_nginx_running; then
    info "스택: 실행 중"
  else
    info "스택: 중지"
  fi
  if [[ -f "$ENV_FILE" ]]; then
    if [[ -n "$(env_get MAXMIND_ACCOUNT_ID)" && -n "$(env_get MAXMIND_LICENSE_KEY)" ]]; then
      ok "deploy/.env: MaxMind 설정됨"
    else
      warn "deploy/.env: MaxMind 값이 비어 있음"
    fi
  else
    warn "deploy/.env: 없음"
  fi

  if [[ "$missing" -ne 0 || "$port_problem" -ne 0 ]]; then
    err "사전 점검을 통과하지 못했습니다."
    return 1
  fi
  ok "사전 점검 통과"
  return 0
}

cmd_env() {
  local account license countries puid pgid tz current
  if [[ ! -f "$ENV_EXAMPLE" ]]; then
    err "deploy/.env.example 이 없습니다."
    return 1
  fi
  if [[ ! -f "$ENV_FILE" ]]; then
    umask 077
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    info "deploy/.env 를 예시에서 만들었습니다."
  fi

  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    account=${OPT_ACCOUNT:-$(env_get MAXMIND_ACCOUNT_ID)}
    license=${OPT_LICENSE:-$(env_get MAXMIND_LICENSE_KEY)}
    countries=${OPT_COUNTRIES:-$(env_get ALLOWED_COUNTRIES)}
    countries=${countries:-KR,JP}
    puid=${OPT_PUID:-$(env_get PUID)}
    puid=${puid:-$(id -u)}
    pgid=${OPT_PGID:-$(env_get PGID)}
    pgid=${pgid:-$(id -g)}
    tz=${OPT_TZ:-$(env_get TZ)}
    tz=${tz:-Asia/Tokyo}
  else
    current=$(env_get MAXMIND_ACCOUNT_ID)
    account=$(prompt "MaxMind 계정 ID" "$current")
    current=$(env_get MAXMIND_LICENSE_KEY)
    if [[ -n "$current" ]]; then
      read -r -s -p "MaxMind 라이선스 키 [설정됨, Enter면 유지]: " license || true
      printf '\n'
      license=${license:-$current}
    else
      read -r -s -p "MaxMind 라이선스 키: " license || true
      printf '\n'
    fi
    current=$(env_get ALLOWED_COUNTRIES)
    current=${current:-KR,JP}
    countries=$(prompt "허용 국가" "$current")
    current=$(env_get PUID)
    current=${current:-$(id -u)}
    puid=$(prompt "PUID" "$current")
    current=$(env_get PGID)
    current=${current:-$(id -g)}
    pgid=$(prompt "PGID" "$current")
    current=$(env_get TZ)
    current=${current:-Asia/Tokyo}
    tz=$(prompt "시간대" "$current")
  fi

  info "기본 포트 80 / 443"
  describe_port 80
  describe_port 443
  local https http https_default http_default
  if port_listening 443 && ! port_is_ours 443; then
    https_default=8443
    warn "443 이 사용 중이어서 HTTPS 기본값을 8443 으로 제안합니다."
  else
    https_default=443
  fi
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    https=${OPT_HTTPS:-$(env_get HTTPS_PORT)}
    https=${https:-$https_default}
    if [[ -z "$OPT_HTTPS" && "$https" == "443" ]] && port_listening 443 && ! port_is_ours 443; then
      https=8443
      warn "443 이 사용 중이어서 HTTPS 포트를 8443 으로 둡니다. --https-port 로 바꿀 수 있습니다."
    fi
    if [[ "$OPT_HTTP_SET" -eq 1 ]]; then
      http=$(normalize_http_port "$OPT_HTTP")
    else
      if [[ -f "$ENV_FILE" ]] && grep -qE '^HTTP_PORT=' "$ENV_FILE"; then
        http=$(env_get HTTP_PORT)
      else
        http=80
      fi
      if [[ "$http" == "80" ]] && port_listening 80 && ! port_is_ours 80; then
        http=""
        warn "80 이 사용 중이어서 HTTP 리다이렉트를 끕니다. --http-port 로 바꿀 수 있습니다."
      fi
    fi
  else
    current=$(env_get HTTPS_PORT)
    current=${current:-$https_default}
    https=$(prompt "HTTPS 포트" "$current")
    if port_listening 80 && ! port_is_ours 80; then
      http_default="none"
      warn "80 이 사용 중입니다. Enter 면 HTTP 를 끕니다. 다른 포트를 입력할 수도 있습니다."
    else
      http_default=$(env_get HTTP_PORT)
      if [[ -z "$http_default" ]] && ! grep -qE '^HTTP_PORT=' "$ENV_FILE" 2>/dev/null; then
        http_default=80
      elif [[ -z "$http_default" ]]; then
        http_default="none"
      fi
    fi
    http=$(prompt "HTTP 리다이렉트 포트 (none=끔)" "$http_default")
    http=$(normalize_http_port "$http")
  fi

  countries=$(printf '%s' "$countries" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
  if [[ -z "$account" || -z "$license" ]]; then
    err "MaxMind 계정 ID 와 라이선스 키는 비울 수 없습니다."
    return 1
  fi
  if ! valid_countries "$countries"; then
    err "허용 국가는 KR,JP 처럼 쉼표로 구분한 두 글자 코드여야 합니다."
    return 1
  fi
  if [[ ! "$puid" =~ ^[0-9]+$ || ! "$pgid" =~ ^[0-9]+$ ]]; then
    err "PUID 와 PGID 는 숫자여야 합니다."
    return 1
  fi
  if [[ -z "$tz" || ! -e "/usr/share/zoneinfo/${tz}" ]]; then
    err "시간대를 확인할 수 없습니다: ${tz}"
    return 1
  fi
  if ! valid_port "$https"; then
    err "HTTPS 포트가 올바르지 않습니다: ${https}"
    return 1
  fi
  if [[ -n "$http" ]] && ! valid_port "$http"; then
    err "HTTP 포트가 올바르지 않습니다: ${http}"
    return 1
  fi
  if [[ -n "$http" && "$http" == "$https" ]]; then
    err "HTTP 포트와 HTTPS 포트는 달라야 합니다."
    return 1
  fi

  env_set MAXMIND_ACCOUNT_ID "$account" || return 1
  env_set MAXMIND_LICENSE_KEY "$license" || return 1
  env_set ALLOWED_COUNTRIES "$countries" || return 1
  env_set PUID "$puid" || return 1
  env_set PGID "$pgid" || return 1
  env_set TZ "$tz" || return 1
  env_set HTTPS_PORT "$https" || return 1
  env_set HTTP_PORT "$http" || return 1
  ok "deploy/.env 를 저장했습니다. 라이선스 키는 출력하지 않습니다."
  info "  계정 ID=${account}  국가=${countries}  PUID=${puid}  PGID=${pgid}  TZ=${tz}"
  info "  HTTPS=${https}  HTTP=${http:-끔}"
  if [[ -n "$(env_get MAXMIND_LICENSE_KEY)" ]]; then
    info "  라이선스 키=설정됨"
  fi
  show_access_url
}

ca_exists() {
  [[ -f "$CERT_DIR/ca/ca.crt" && -f "$CERT_DIR/ca/ca.key" ]]
}

server_exists() {
  [[ -f "$CERT_DIR/server/server.crt" && -f "$CERT_DIR/server/server.key" ]]
}

cmd_ca() {
  if ca_exists; then
    ok "CA가 이미 있습니다: ${CERT_DIR}/ca/ca.crt"
    return 0
  fi
  "$GEN_CERTS" init
}

cmd_server() {
  local cn extra san
  if server_exists; then
    ok "서버 인증서가 이미 있습니다: ${CERT_DIR}/server/server.crt"
    return 0
  fi
  if ! ca_exists; then
    err "CA가 없습니다. 먼저 CA를 만드세요."
    return 1
  fi
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    cn=${OPT_CN:-}
    extra=${OPT_EXTRA:-}
    if [[ -z "$cn" ]]; then
      err "도메인이 필요합니다. 예: ./webtop.sh server --cn webtop.example.com"
      return 1
    fi
  else
    cn=$(prompt "서버 도메인" "webtop.local")
    extra=$(prompt "추가 이름 또는 IP (쉼표, 없으면 Enter)" "")
  fi
  if ! valid_cn "$cn"; then
    err "도메인 형식이 올바르지 않습니다."
    return 1
  fi
  san=$(build_san "$cn" "$extra")
  info "SAN=${san}"
  "$GEN_CERTS" server --cn "$cn" --san "$san"
}

client_cert_path() {
  printf '%s/clients/%s.crt' "$CERT_DIR" "$1"
}

cmd_client() {
  local name pass
  if ! ca_exists; then
    err "CA가 없습니다. 먼저 CA를 만드세요."
    return 1
  fi
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    name=${OPT_NAME:-}
    pass=${OPT_P12:-${P12_PASS:-}}
    if [[ -z "$name" || -z "$pass" ]]; then
      err "이름과 비밀번호가 필요합니다. 예: ./webtop.sh client laptop --p12-pass '비밀번호'"
      return 1
    fi
  else
    name=$(prompt "장치 이름" "")
    if [[ -z "$name" ]]; then
      err "장치 이름이 필요합니다."
      return 1
    fi
    pass=""
    prompt_secret pass "PKCS#12 비밀번호" || return 1
  fi
  if ! valid_name "$name"; then
    err "장치 이름은 영문, 숫자, ., _, - 만 사용할 수 있습니다."
    return 1
  fi
  if [[ -f "$(client_cert_path "$name")" ]]; then
    ok "클라이언트 인증서가 이미 있습니다: $(client_cert_path "$name")"
    return 0
  fi
  local log rc
  log=$(mktemp)
  P12_PASS="$pass" "$GEN_CERTS" client "$name" >"$log" 2>&1
  rc=$?
  grep -v '^PKCS#12 password:' "$log" || true
  rm -f "$log"
  if [[ "$rc" -ne 0 ]]; then
    err "클라이언트 인증서 발급에 실패했습니다."
    return 1
  fi
  ok "발급했습니다."
  info "  인증서  ${CERT_DIR}/clients/${name}.crt"
  info "  개인키  ${CERT_DIR}/clients/${name}.key"
  info "  PKCS#12 ${CERT_DIR}/clients/${name}.p12"
}

cmd_list() {
  local index="$CERT_DIR/index.txt"
  if [[ ! -f "$index" ]]; then
    err "CA 목록이 없습니다. 먼저 CA를 만드세요."
    return 1
  fi
  local shown=0
  printf '%-8s %-12s %-8s %s\n' "상태" "만료" "시리얼" "이름"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    local status expiry serial subject cn label
    status=$(printf '%s' "$line" | awk -F '\t' '{print $1}')
    expiry=$(printf '%s' "$line" | awk -F '\t' '{print $2}')
    serial=$(printf '%s' "$line" | awk -F '\t' '{print $4}')
    subject=$(printf '%s' "$line" | awk -F '\t' '{print $6}')
    cn=$(printf '%s' "$subject" | sed -n 's|.*/CN=\([^/]*\).*|\1|p')
    [[ -n "$cn" && -f "$(client_cert_path "$cn")" ]] || continue
    case "$status" in
      V) label="유효" ;;
      R) label="폐기" ;;
      E) label="만료" ;;
      *) label="$status" ;;
    esac
    printf '%-8s %-12s %-8s %s\n' "$label" "$(fmt_openssl_date "$expiry")" "$serial" "$cn"
    shown=1
  done <"$index"
  if [[ "$shown" -eq 0 ]]; then
    info "발급된 클라이언트 인증서가 없습니다."
  fi
}

reload_nginx_if_running() {
  if stack_nginx_running; then
    info "Nginx 설정을 다시 읽습니다."
    compose exec -T nginx nginx -s reload
  else
    info "Nginx 가 실행 중이 아니어서 리로드는 생략했습니다."
  fi
}

cmd_revoke() {
  local name answer
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    name=${OPT_NAME:-}
  else
    name=$(prompt "폐기할 장치 이름" "")
  fi
  if [[ -z "$name" ]]; then
    err "장치 이름이 필요합니다."
    return 1
  fi
  if ! valid_name "$name"; then
    err "장치 이름 형식이 올바르지 않습니다."
    return 1
  fi
  if [[ ! -f "$(client_cert_path "$name")" ]]; then
    err "인증서가 없습니다: ${name}"
    return 1
  fi
  if [[ "$NONINTERACTIVE" -eq 0 ]]; then
    answer=$(prompt "${name} 인증서를 폐기할까요? (y/N)" "N")
    [[ "$answer" == "y" || "$answer" == "Y" ]] || { info "취소했습니다."; return 0; }
  fi
  "$GEN_CERTS" revoke "$name" || return 1
  if require_env_file; then
    reload_nginx_if_running || return 1
  fi
}

show_access_url() {
  local port host cn subject
  port=$(https_port_configured)
  host="localhost"
  if [[ -f "$CERT_DIR/server/server.crt" ]] && have openssl; then
    subject=$(openssl x509 -in "$CERT_DIR/server/server.crt" -noout -subject 2>/dev/null || true)
    cn=$(printf '%s' "$subject" | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p')
    cn=${cn#"${cn%%[![:space:]]*}"}
    [[ -n "$cn" ]] && host=$cn
  fi
  if [[ "$port" == "443" ]]; then
    ok "접속 주소: https://${host}/"
  else
    ok "접속 주소: https://${host}:${port}/"
  fi
}

cmd_start() {
  require_env_file || return 1
  if [[ -z "$(env_get MAXMIND_ACCOUNT_ID)" || -z "$(env_get MAXMIND_LICENSE_KEY)" ]]; then
    err "MaxMind 설정이 비어 있습니다. 초기 설정을 먼저 하세요."
    return 1
  fi
  compose up -d --build
  show_access_url
}

cmd_stop() {
  require_env_file || return 1
  compose stop
}

cmd_restart() {
  require_env_file || return 1
  compose restart
}

cmd_status() {
  require_env_file || return 1
  compose ps
}

cmd_logs() {
  local svc=${OPT_SERVICE:-}
  if [[ -z "$svc" ]]; then
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      err "서비스가 필요합니다. 예: ./webtop.sh logs nginx"
      return 1
    fi
    svc=$(prompt "서비스 (webtop/nginx/geoipupdate)" "nginx")
  fi
  case "$svc" in
    webtop|nginx|geoipupdate) ;;
    *) err "서비스는 webtop, nginx, geoipupdate 중 하나여야 합니다."; return 1 ;;
  esac
  require_env_file || return 1
  if [[ "$NONINTERACTIVE" -eq 1 || ! -t 1 ]]; then
    compose logs --tail=100 "$svc"
    return $?
  fi
  info "Ctrl+C 를 누르면 메뉴로 돌아갑니다."
  compose logs -f --tail=100 "$svc" || true
  return 0
}

cmd_access() {
  if [[ ! -f "$ACCESS_LOG" ]]; then
    warn "아직 접속 로그가 없습니다: ${ACCESS_LOG}"
    return 0
  fi
  tail -n 80 "$ACCESS_LOG"
}

host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) printf '' ;;
  esac
}

ghcr_token() {
  local body
  body=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:krsuhjunho/webtop:pull") || return 1
  printf '%s' "$body" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

ghcr_manifest() {
  local token=$1 ref=$2 accept=$3
  curl -fsSL \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: ${accept}" \
    "https://ghcr.io/v2/krsuhjunho/webtop/manifests/${ref}"
}

ghcr_digest_header() {
  local token=$1 ref=$2
  curl -fsSL -D - -o /dev/null \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://ghcr.io/v2/krsuhjunho/webtop/manifests/${ref}" \
    | awk 'BEGIN { IGNORECASE = 1 } tolower($1)=="docker-content-digest:" { print $2; exit }' \
    | tr -d '\r'
}

remote_release() {
  local token arch index_json arch_digest manifest
  token=$(ghcr_token) || return 1
  [[ -n "$token" ]] || return 1
  arch=$(host_arch)
  [[ -n "$arch" ]] || { err "지원하지 않는 아키텍처입니다: $(uname -m)"; return 1; }
  index_json=$(ghcr_manifest "$token" latest "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json") || return 1
  REMOTE_INDEX=$(ghcr_digest_header "$token" latest)
  arch_digest=$(printf '%s' "$index_json" | awk -v want="$arch" '
    match($0, /sha256:[0-9a-f]+/) { last = substr($0, RSTART, RLENGTH) }
    /"architecture"/ {
      if (match($0, /"architecture"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        arch = substr($0, RSTART, RLENGTH)
        gsub(/.*"architecture"[[:space:]]*:[[:space:]]*"/, "", arch)
        sub(/".*/, "", arch)
        if (arch == want && last != "") { print last; exit }
      }
    }
  ')
  [[ -n "$arch_digest" && -n "$REMOTE_INDEX" ]] || return 1
  REMOTE_ARCH=$arch_digest
  manifest=$(ghcr_manifest "$token" "$arch_digest" "application/vnd.oci.image.manifest.v1+json") || return 1
  REMOTE_CONFIG=$(printf '%s' "$manifest" | awk '
    /"config"/ { in_config = 1 }
    in_config && match($0, /sha256:[0-9a-f]+/) { print substr($0, RSTART, RLENGTH); exit }
  ')
  [[ -n "$REMOTE_CONFIG" ]] || return 1
  REMOTE_DATE=$(date_tag_for_index "$token" "$REMOTE_INDEX")
}

date_tag_for_index() {
  local token=$1 want=$2 tags tag digest
  tags=$(curl -fsSL -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/krsuhjunho/webtop/tags/list") || return 0
  for tag in $(printf '%s' "$tags" | grep -oE '"[0-9]{6}"' | tr -d '"'); do
    digest=$(ghcr_digest_header "$token" "$tag") || continue
    if [[ "$digest" == "$want" ]]; then
      printf '%s' "$tag"
      return 0
    fi
  done
}

image_repo_digest() {
  local id=$1
  docker image inspect "$id" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null | head -n 1
}

digest_only() {
  local ref=$1
  printf '%s' "${ref##*@}"
}

collect_local_image() {
  LOCAL_ID=""
  LOCAL_REPO=""
  RUN_ID=""
  RUN_REPO=""
  LOCAL_DATE=""
  RUN_DATE=""
  if docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
    LOCAL_ID=$(docker image inspect "$IMAGE_REF" --format '{{.Id}}')
    LOCAL_REPO=$(image_repo_digest "$IMAGE_REF")
  fi
  if docker inspect webtop >/dev/null 2>&1; then
    RUN_ID=$(docker inspect webtop --format '{{.Image}}')
    RUN_REPO=$(image_repo_digest "$RUN_ID")
  fi
}

date_tag_for_repo() {
  local repo=$1 token want
  want=$(digest_only "$repo")
  [[ -n "$want" ]] || return 0
  token=$(ghcr_token) || return 0
  date_tag_for_index "$token" "$want"
}

images_current() {
  [[ -n "${REMOTE_CONFIG:-}" ]] || return 1
  local remote_id="sha256:${REMOTE_CONFIG#sha256:}" saw=0
  if [[ -n "${LOCAL_ID:-}" ]]; then
    saw=1
    [[ "$LOCAL_ID" == "$remote_id" ]] || return 1
  fi
  if [[ -n "${RUN_ID:-}" ]]; then
    saw=1
    [[ "$RUN_ID" == "$remote_id" ]] || return 1
  fi
  [[ "$saw" -eq 1 ]]
}

report_versions() {
  local remote_id="sha256:${REMOTE_CONFIG#sha256:}"
  LOCAL_DATE=$(date_tag_for_repo "$LOCAL_REPO")
  RUN_DATE=$(date_tag_for_repo "$RUN_REPO")
  info "아키텍처: linux/$(host_arch)"
  if [[ -n "$RUN_ID" ]]; then
    info "실행 중: ${RUN_ID}  날짜 태그: ${RUN_DATE:-없음}"
  else
    info "실행 중: 없음"
  fi
  if [[ -n "$LOCAL_ID" ]]; then
    info "로컬 이미지: ${LOCAL_ID}  날짜 태그: ${LOCAL_DATE:-없음}"
  else
    info "로컬 이미지: 없음"
  fi
  info "원격 latest ($(host_arch)): ${remote_id}"
  info "원격 매니페스트: ${REMOTE_ARCH}  날짜 태그: ${REMOTE_DATE:-없음}"
}

cmd_check_update() {
  have docker || { err "docker 가 없습니다."; return 1; }
  info "원격 이미지를 확인합니다."
  remote_release || { err "GHCR 에서 latest 를 읽지 못했습니다."; return 1; }
  collect_local_image
  report_versions
  if images_current; then
    ok "최신입니다."
    return 0
  fi
  warn "새 버전이 있습니다."
  return 10
}

prune_old_images() {
  info "사용하지 않는 webtop 이미지를 지웁니다."
  docker image prune -f --filter "label=org.opencontainers.image.title=webtop" >/dev/null || true
}

cmd_update() {
  local answer
  require_env_file || return 1
  cmd_check_update
  local rc=$?
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$rc" -ne 10 ]]; then
    return "$rc"
  fi
  if [[ "$NONINTERACTIVE" -eq 1 && "$OPT_YES" -ne 1 ]]; then
    err "적용하려면 --yes 를 붙이세요."
    return 10
  fi
  if [[ "$NONINTERACTIVE" -eq 0 ]]; then
    answer=$(prompt "업데이트할까요? (y/N)" "N")
    [[ "$answer" == "y" || "$answer" == "Y" ]] || { info "취소했습니다."; return 0; }
  fi
  compose pull
  compose up -d --build
  if [[ "$OPT_PRUNE" -eq 1 || "$(env_get UPDATE_PRUNE)" == "1" ]]; then
    prune_old_images
  elif [[ "$NONINTERACTIVE" -eq 0 ]]; then
    answer=$(prompt "이전 dangling 이미지를 지울까요? (y/N)" "N")
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
      prune_old_images
    fi
  fi
  show_access_url
}

cmd_auto_update() {
  local mode
  mkdir -p "$ROOT/deploy/logs"
  if ! have flock; then
    err "flock 이 없습니다."
    return 1
  fi
  if [[ "${WEBTOP_FLOCKED:-}" != "1" ]]; then
    exec 9>>"$UPDATE_LOCK"
    if ! flock -n 9; then
      info "다른 업데이트가 실행 중입니다."
      return 0
    fi
  fi
  mode=$(env_get UPDATE_MODE)
  mode=${mode:-check}
  info "===== $(date -Is) auto-update mode=${mode} ====="
  if [[ "$mode" == "apply" ]]; then
    OPT_YES=1
    cmd_update
    return $?
  fi
  cmd_check_update || true
  return 0
}

cron_marker='# webtop-managed'
cron_schedule_default='0 6 * * 1'

valid_schedule() {
  local text=$1 words
  [[ -n "$text" && "$text" != *$'\n'* ]] || return 1
  words=$(printf '%s' "$text" | awk '{print NF}')
  [[ "$words" -eq 5 ]]
}

cron_command_line() {
  local schedule=$1 flock_bin
  flock_bin=$(command -v flock)
  printf '%s %s -n %s env WEBTOP_FLOCKED=1 %s auto-update >> %s 2>&1\n' \
    "$schedule" "$flock_bin" "$UPDATE_LOCK" "$ROOT/webtop.sh" "$UPDATE_LOG"
}

cmd_cron_menu() {
  local choice
  cmd_cron_status || true
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    return 0
  fi
  choice=$(prompt "1=등록 2=제거 0=돌아가기" "0")
  case "$choice" in
    1) cmd_cron_install ;;
    2) cmd_cron_remove ;;
    *) info "돌아갑니다." ;;
  esac
}

read_crontab() {
  "$CRONTAB" -l 2>/dev/null || true
}

write_crontab() {
  local file=$1
  "$CRONTAB" "$file"
}

cmd_cron_status() {
  local line found=0
  info "UPDATE_MODE=$(env_get UPDATE_MODE)"
  while IFS= read -r line; do
    [[ "$line" == *'webtop.sh auto-update'* || "$line" == "$cron_marker" ]] || continue
    info "$line"
    found=1
  done < <(read_crontab)
  if [[ "$found" -eq 0 ]]; then
    info "등록된 webtop cron 이 없습니다."
  fi
}

cmd_cron_remove() {
  local tmp
  if ! have "$CRONTAB" && [[ "$CRONTAB" == "crontab" ]]; then
    err "crontab 명령이 없습니다."
    return 1
  fi
  tmp=$(mktemp)
  read_crontab | awk '
    $0 == "# webtop-managed" { skip = 1; next }
    /webtop\.sh auto-update/ { next }
    { print }
  ' >"$tmp"
  write_crontab "$tmp"
  rm -f "$tmp"
  ok "webtop cron 을 제거했습니다."
}

cmd_cron_install() {
  local schedule mode tmp
  if ! have flock; then
    err "flock 이 없습니다."
    return 1
  fi
  if ! command -v "$CRONTAB" >/dev/null 2>&1; then
    err "crontab 명령이 없습니다."
    return 1
  fi
  require_env_file || return 1
  schedule=${OPT_SCHEDULE:-$cron_schedule_default}
  mode=${OPT_MODE:-$(env_get UPDATE_MODE)}
  mode=${mode:-check}
  if [[ "$NONINTERACTIVE" -eq 0 ]]; then
    schedule=$(prompt "cron 식 (분 시 일 월 요일)" "$schedule")
    mode=$(prompt "모드 check 또는 apply" "$mode")
  fi
  if ! valid_schedule "$schedule"; then
    err "cron 식은 다섯 칸이어야 합니다."
    return 1
  fi
  if [[ "$mode" != "check" && "$mode" != "apply" ]]; then
    err "모드는 check 또는 apply 여야 합니다."
    return 1
  fi
  env_set UPDATE_MODE "$mode" || return 1
  mkdir -p "$ROOT/deploy/logs"
  tmp=$(mktemp)
  read_crontab | awk '
    $0 == "# webtop-managed" { skip = 1; next }
    /webtop\.sh auto-update/ { next }
    { print }
  ' >"$tmp"
  printf '%s\n' "$cron_marker" >>"$tmp"
  cron_command_line "$schedule" >>"$tmp"
  write_crontab "$tmp"
  rm -f "$tmp"
  ok "cron 을 등록했습니다. 모드=${mode}"
  info "$(cron_command_line "$schedule")"
  if [[ "$mode" == "check" ]]; then
    info "새 버전이 있으면 deploy/logs/update.log 에만 남깁니다."
  else
    info "새 버전이 있으면 확인 없이 적용합니다."
  fi
}

any_client_cert() {
  local found
  found=$(find "$CERT_DIR/clients" -name '*.crt' -print -quit 2>/dev/null || true)
  [[ -n "$found" ]]
}

cmd_install() {
  info "전체 자동 설치를 시작합니다."
  have docker || { err "docker 가 없습니다."; return 1; }
  have openssl || { err "openssl 이 없습니다."; return 1; }
  have git || { err "git 이 없습니다."; return 1; }
  docker compose version >/dev/null 2>&1 || { err "docker compose 가 없습니다."; return 1; }
  if [[ -f "$ENV_FILE" && -n "$(env_get MAXMIND_ACCOUNT_ID)" && -n "$(env_get MAXMIND_LICENSE_KEY)" && -z "$OPT_ACCOUNT" && -z "$OPT_LICENSE" && -z "$OPT_HTTPS" && "$OPT_HTTP_SET" -eq 0 && -z "$OPT_COUNTRIES" && -z "$OPT_PUID" && -z "$OPT_PGID" && -z "$OPT_TZ" ]]; then
    ok "초기 설정이 이미 있습니다. 건너뜁니다."
  else
    cmd_env || return 1
  fi
  cmd_precheck_ports || return 1
  if ca_exists; then
    ok "CA 생성을 건너뜁니다."
  else
    cmd_ca || return 1
  fi
  if server_exists; then
    ok "서버 인증서 발급을 건너뜁니다."
  else
    cmd_server || return 1
  fi
  if any_client_cert && [[ -z "$OPT_NAME" ]]; then
    ok "클라이언트 인증서가 이미 있습니다. 건너뜁니다."
  else
    cmd_client || return 1
  fi
  if stack_nginx_running; then
    ok "스택이 이미 실행 중입니다. 시작을 건너뜁니다."
  else
    cmd_start || return 1
  fi
  ok "자동 설치가 끝났습니다."
}

draw_menu() {
  printf '\n%s======== Webtop 관리 ========%s\n' "$C_CYAN" "$C_OFF"
  cat <<'EOF'
 1) 사전 점검
 2) 초기 설정
 3) CA 생성
 4) 서버 인증서 발급
 5) 클라이언트 인증서 발급
 6) 클라이언트 인증서 목록
 7) 클라이언트 인증서 폐기
 8) 스택 시작
 9) 스택 중지
10) 스택 재시작
11) 상태
12) 로그 보기
13) 접속 로그 보기
14) 이미지 업데이트
15) 전체 자동 설치
16) 업데이트 확인
17) 주간 자동 확인
 0) 종료
EOF
}

menu_once() {
  local choice=$1
  case "$choice" in
    1) cmd_precheck || true ;;
    2) cmd_env || true ;;
    3) cmd_ca || true ;;
    4) cmd_server || true ;;
    5) cmd_client || true ;;
    6) cmd_list || true ;;
    7) cmd_revoke || true ;;
    8) cmd_start || true ;;
    9) cmd_stop || true ;;
    10) cmd_restart || true ;;
    11) cmd_status || true ;;
    12) OPT_SERVICE=""; cmd_logs || true ;;
    13) cmd_access || true ;;
    14) cmd_update || true ;;
    15) cmd_install || true ;;
    16) cmd_check_update || true ;;
    17) cmd_cron_menu || true ;;
    0|q|Q|exit) return 10 ;;
    "") ;;
    *) err "없는 번호입니다: ${choice}" ;;
  esac
  return 0
}

menu_loop() {
  local choice rc
  while true; do
    draw_menu
    if ! read -r -p "번호: " choice; then
      printf '\n'
      if [[ ! -t 0 ]]; then
        return 0
      fi
      continue
    fi
    menu_once "$choice"
    rc=$?
    if [[ "$rc" -eq 10 ]]; then
      info "종료합니다."
      return 0
    fi
    [[ "$choice" == "0" ]] && return 0
    pause
  done
}

parse_opts() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --account) OPT_ACCOUNT=$2; shift 2 ;;
      --license) OPT_LICENSE=$2; shift 2 ;;
      --countries) OPT_COUNTRIES=$2; shift 2 ;;
      --puid) OPT_PUID=$2; shift 2 ;;
      --pgid) OPT_PGID=$2; shift 2 ;;
      --tz) OPT_TZ=$2; shift 2 ;;
      --https-port) OPT_HTTPS=$2; shift 2 ;;
      --http-port) OPT_HTTP=$2; OPT_HTTP_SET=1; shift 2 ;;
      --schedule) OPT_SCHEDULE=$2; shift 2 ;;
      --mode) OPT_MODE=$2; shift 2 ;;
      --yes) OPT_YES=1; shift ;;
      --prune) OPT_PRUNE=1; shift ;;
      --cn) OPT_CN=$2; shift 2 ;;
      --extra) OPT_EXTRA=$2; shift 2 ;;
      --name) OPT_NAME=$2; shift 2 ;;
      --p12-pass) OPT_P12=$2; shift 2 ;;
      --service) OPT_SERVICE=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -*)
        err "알 수 없는 옵션: $1"
        usage
        exit 1
        ;;
      *)
        if [[ -z "$OPT_NAME" ]]; then
          OPT_NAME=$1
        elif [[ -z "$OPT_SERVICE" ]]; then
          OPT_SERVICE=$1
        else
          err "알 수 없는 인자: $1"
          usage
          exit 1
        fi
        shift
        ;;
    esac
  done
}

main() {
  local cmd
  if [[ $# -eq 0 ]]; then
    menu_loop
    return 0
  fi
  NONINTERACTIVE=1
  cmd=$1
  shift
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
  esac
  parse_opts "$@"
  case "$cmd" in
    precheck|check) cmd_precheck ;;
    env|setup) cmd_env ;;
    ca|init-ca) cmd_ca ;;
    server) cmd_server ;;
    client) cmd_client ;;
    list|clients) cmd_list ;;
    revoke) cmd_revoke ;;
    start|up) cmd_start ;;
    stop|down) cmd_stop ;;
    restart) cmd_restart ;;
    status|ps) cmd_status ;;
    logs)
      OPT_SERVICE=${OPT_SERVICE:-$OPT_NAME}
      OPT_NAME=""
      cmd_logs
      ;;
    access) cmd_access ;;
    update|pull) cmd_update ;;
    check-update) cmd_check_update ;;
    auto-update) cmd_auto_update ;;
    cron-install) cmd_cron_install ;;
    cron-remove) cmd_cron_remove ;;
    cron-status) cmd_cron_status ;;
    install) cmd_install ;;
    *)
      err "알 수 없는 명령: ${cmd}"
      usage
      return 1
      ;;
  esac
}

main "$@"
