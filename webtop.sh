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

NONINTERACTIVE=0
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
  update                이미지 업데이트
  install               전체 자동 설치

옵션:
  --account ID          MaxMind 계정 ID
  --license KEY         MaxMind 라이선스 키 (프로세스 목록에 보일 수 있음)
  --countries KR,JP
  --puid N  --pgid N  --tz Asia/Tokyo
  --cn 도메인  --extra name,ip
  --name 장치  --p12-pass 비밀번호
  --service webtop|nginx|geoipupdate
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
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
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

  info "포트 80 / 443"
  local port
  for port in 80 443; do
    if port_listening "$port"; then
      if stack_nginx_running; then
        warn "  ${port} 사용 중 (webtop-nginx)"
      else
        err "  ${port} 다른 프로세스가 사용 중"
        port_problem=1
      fi
    else
      ok "  ${port} 사용 가능"
    fi
  done

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

  env_set MAXMIND_ACCOUNT_ID "$account" || return 1
  env_set MAXMIND_LICENSE_KEY "$license" || return 1
  env_set ALLOWED_COUNTRIES "$countries" || return 1
  env_set PUID "$puid" || return 1
  env_set PGID "$pgid" || return 1
  env_set TZ "$tz" || return 1
  ok "deploy/.env 를 저장했습니다. 라이선스 키는 출력하지 않습니다."
  info "  계정 ID=${account}  국가=${countries}  PUID=${puid}  PGID=${pgid}  TZ=${tz}"
  if [[ -n "$(env_get MAXMIND_LICENSE_KEY)" ]]; then
    info "  라이선스 키=설정됨"
  fi
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

cmd_start() {
  require_env_file || return 1
  if [[ -z "$(env_get MAXMIND_ACCOUNT_ID)" || -z "$(env_get MAXMIND_LICENSE_KEY)" ]]; then
    err "MaxMind 설정이 비어 있습니다. 초기 설정을 먼저 하세요."
    return 1
  fi
  compose up -d --build
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

cmd_update() {
  require_env_file || return 1
  compose pull
  compose up -d --build
}

any_client_cert() {
  local found
  found=$(find "$CERT_DIR/clients" -name '*.crt' -print -quit 2>/dev/null || true)
  [[ -n "$found" ]]
}

cmd_install() {
  info "전체 자동 설치를 시작합니다."
  cmd_precheck || return 1
  if [[ -f "$ENV_FILE" && -n "$(env_get MAXMIND_ACCOUNT_ID)" && -n "$(env_get MAXMIND_LICENSE_KEY)" && -z "$OPT_ACCOUNT" && -z "$OPT_LICENSE" ]]; then
    ok "초기 설정이 이미 있습니다. 건너뜁니다."
  else
    cmd_env || return 1
  fi
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
    install) cmd_install ;;
    *)
      err "알 수 없는 명령: ${cmd}"
      usage
      return 1
      ;;
  esac
}

main "$@"
