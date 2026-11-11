#!/usr/bin/env bash
# Interactive and non-interactive lifecycle for the webtop mTLS stack.
# Secrets are never printed. Failures return to the menu instead of exiting.

set -u

# Follow symlinks so `webtop` in /usr/local/bin still uses this repo.
script_realpath() {
  local src=$1 dir target resolved
  if [[ "$src" != */* ]]; then
    resolved=$(command -v "$src" 2>/dev/null || true)
    if [[ -n "$resolved" ]]; then
      src=$resolved
    fi
  fi
  if command -v readlink >/dev/null 2>&1; then
    resolved=$(readlink -f "$src" 2>/dev/null || true)
    if [[ -n "$resolved" && -e "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi
  if command -v realpath >/dev/null 2>&1; then
    resolved=$(realpath "$src" 2>/dev/null || true)
    if [[ -n "$resolved" && -e "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi
  while [[ -L "$src" ]]; do
    target=$(readlink "$src" 2>/dev/null || true)
    [[ -n "$target" ]] || break
    if [[ "$target" != /* ]]; then
      dir=$(cd "$(dirname "$src")" && pwd) || return 1
      src="${dir}/${target}"
    else
      src=$target
    fi
  done
  dir=$(cd "$(dirname "$src")" && pwd) || return 1
  printf '%s/%s\n' "$dir" "$(basename "$src")"
}

SCRIPT_PATH=$(script_realpath "${BASH_SOURCE[0]}") || exit 1
ROOT=$(cd "$(dirname "$SCRIPT_PATH")" && pwd) || exit 1
ENV_EXAMPLE="$ROOT/deploy/.env.example"
ENV_FILE="$ROOT/deploy/.env"
COMPOSE_FILE="$ROOT/deploy/docker-compose.yml"
COMPOSE_HTTP="$ROOT/deploy/compose.http.yml"
COMPOSE_OVERRIDE="$ROOT/deploy/compose.override.yml"
CERT_DIR="$ROOT/deploy/certs"
GEN_CERTS="$ROOT/scripts/gen-certs.sh"
ACCESS_LOG="${WEBTOP_ACCESS_LOG:-$ROOT/deploy/logs/access.log}"
CERTADMIN_LOG="${WEBTOP_CERTADMIN_LOG:-$ROOT/deploy/logs/certadmin.log}"
LOG_TAIL=100
UPDATE_LOG="${WEBTOP_UPDATE_LOG:-$ROOT/deploy/logs/update.log}"
UPDATE_LOCK="$ROOT/deploy/logs/update.lock"
IMAGE_NAME="ghcr.io/krsuhjunho/webtop"
IMAGE_REF="${IMAGE_NAME}:latest"
CRONTAB=${CRONTAB:-crontab}

NONINTERACTIVE=0
OPT_YES=0
OPT_PRUNE=0
OPT_STASH=0
OPT_CHECK=0
OPT_HTTP_SET=0
OPT_ADMIN=0
FORCE_ADMIN=0
OPT_MINUTES=""
OPT_CN=""
OPT_EXTRA=""
OPT_NAME=""
OPT_P12=""
OPT_KEEP=0
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
OPT_CONSTRAINTS=()
OPT_PROFILE=""
OPT_VARIANT=""

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
    err "비밀번호는 대화형으로 묻거나, 비우면 임의로 만들어 한 번만 보여 줍니다."
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
  ca [--name-constraint 이름]
                        CA 생성. 제약은 새 CA 에만 들어가며 반복할 수 있습니다
  server                서버 인증서 발급
  client <이름> [--admin] [--keep] 클라이언트 인증서 발급. --admin 이면 OU=admin
                        비밀번호는 대화형으로 묻습니다. 비우면 임의로 만들어 한 번만 보여 줍니다.
                        --keep 만 서버에 .p12 를 남깁니다
  enroll                일회용 등록 링크 출력 (--name, --minutes)
  list                  클라이언트 인증서 목록
  revoke <이름>         클라이언트 인증서 폐기 후 Nginx 리로드
  start                 스택 시작
  stop                  스택 중지
  restart               스택 재시작
  status                상태. 맨 위에 버전 한 줄
  version               스크립트, 변형, 실행 중 이미지, 캐시된 업데이트 상태
                        -v, --version 와 같음. --check 는 캐시를 새로 고칩니다
  logs [서비스]         컨테이너 로그. 없으면 all
                        webtop|nginx|geoipupdate|certadmin|filebrowser|all
  access                접속 로그 (access-log 와 같음)
  access-log [종류]     access|certadmin|update. 메뉴에서는 따라가기
  geo-status            GeoIP DB, 허용 국가, Nginx 네트워크 모드
  geo-test <ip>         그 IP 를 Nginx 의 mmdb 로 조회하고 허용/거부를 출력
  profile <이름>        low-power, balanced, quality. Selkies 전용
  variant [selkies|kasm] 데스크톱 변형. selkies 는 :latest, kasm 은 :kasm
  filebrowser on|off|status|password
                        선택 파일 브라우저. 기본은 끔
  self-update           저장소를 origin/main 으로 fast-forward. upgrade 와 같음
  update                선택한 태그에 새 버전이 있을 때만 이미지 업데이트
  check-update          이미지와 저장소가 뒤처졌는지 확인
  motd                  로그인 알림. 오래됐으면 지금 업데이트할지 묻습니다
  login-check           motd 와 같음. install, uninstall, status, refresh
  auto-update           cron 용. UPDATE_MODE 에 따라 확인 또는 적용
  cron-install          주간 cron 등록
  cron-remove           주간 cron 제거
  cron-status           주간 cron 상태
  link [이름]           /usr/local/bin 링크와 로그인 알림. 기본 이름은 webtop
  install               전체 자동 설치

옵션:
  --account ID          MaxMind 계정 ID
  --license KEY         MaxMind 라이선스 키 (프로세스 목록에 보일 수 있음)
  --countries KR,JP
  --puid N  --pgid N  --tz Asia/Tokyo
  --https-port N        외부 HTTPS 포트 (기본 443)
  --http-port N|none    HTTP 리다이렉트 포트. none 이면 끔
  --cn 도메인  --extra name,ip
  --name 장치  --admin  --minutes N  --keep
                        PKCS#12 비밀번호는 프롬프트로 입력합니다.
                        --p12-pass 는 셸 기록에 남으므로 쓰지 마세요.
  --name-constraint 도메인|IP
                        새 CA 가 서명할 수 있는 이름. 반복 가능
  --service webtop|nginx|geoipupdate|certadmin|filebrowser|all
  geo-test 의 IP 는 명령 뒤에 그대로 적습니다
  --profile low-power|balanced|quality
  --variant selkies|kasm  기본은 selkies (:latest). kasm 은 XFCE (:kasm)
  --yes                 업데이트 확인 질문을 생략
  --check               self-update 는 가져올 커밋만, version 은 캐시를 새로 고칩니다
  --stash               self-update 전에 추적 파일의 로컬 변경을 stash 합니다
  --prune               적용 후 이전 dangling 이미지 삭제
  --schedule '0 14 * * 1'
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
  local http with_fb=0
  if [[ "${1:-}" == "--with-filebrowser" ]]; then
    with_fb=1
    shift
  fi
  ensure_variant_env || return 1
  apply_config_source
  export FILEBROWSER_NOAUTH
  FILEBROWSER_NOAUTH=$(filebrowser_noauth_value)
  args=(--env-file "$ENV_FILE" -f "$COMPOSE_FILE")
  http=$(env_get HTTP_PORT)
  if [[ -n "$http" ]]; then
    args+=(-f "$COMPOSE_HTTP")
  fi
  # Explicit -f disables Compose's automatic override. Add it last so a
  # bind-mounted /config replaces the named volume.
  if [[ -f "$COMPOSE_OVERRIDE" ]]; then
    args+=(-f "$COMPOSE_OVERRIDE")
  fi
  if [[ "$with_fb" -eq 1 ]] || filebrowser_enabled; then
    args+=(--profile filebrowser)
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

ensure_proxy_secret() {
  local cur
  cur=$(env_get CERTADMIN_PROXY_SECRET)
  if [[ -z "$cur" ]]; then
    cur=$(openssl rand -hex 32)
    env_set CERTADMIN_PROXY_SECRET "$cur" || return 1
  fi
}

require_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    err "deploy/.env 가 없습니다. 먼저 초기 설정을 실행하세요."
    return 1
  fi
  ensure_proxy_secret || return 1
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

# selkies is the KDE image on :latest. kasm is the XFCE image on :kasm.
normalize_variant() {
  local raw=${1,,}
  case "$raw" in
    ""|selkies|kde) printf 'selkies' ;;
    kasm|kasmvnc|xfce) printf 'kasm' ;;
    *) return 1 ;;
  esac
}

variant_moving_tag() {
  case "$1" in
    kasm) printf 'kasm' ;;
    *) printf 'latest' ;;
  esac
}

# Empty or a moving tag follows the variant. A pinned tag is left alone.
ensure_variant_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  local variant raw tag current
  raw=$(env_get WEBTOP_VARIANT)
  if ! variant=$(normalize_variant "${raw:-selkies}"); then
    err "WEBTOP_VARIANT 는 selkies 또는 kasm 이어야 합니다: ${raw}"
    return 1
  fi
  if [[ "$raw" != "$variant" ]]; then
    env_set WEBTOP_VARIANT "$variant" || return 1
  fi
  tag=$(variant_moving_tag "$variant")
  current=$(env_get IMAGE_TAG)
  case "$current" in
    ""|latest|kasm)
      if [[ "$current" != "$tag" ]]; then
        env_set IMAGE_TAG "$tag" || return 1
      fi
      ;;
  esac
}

image_tag_for_update() {
  local tag variant
  tag=$(env_get IMAGE_TAG)
  if [[ -n "$tag" ]]; then
    printf '%s' "$tag"
    return 0
  fi
  if ! variant=$(normalize_variant "$(env_get WEBTOP_VARIANT)"); then
    variant=selkies
  fi
  variant=${variant:-selkies}
  variant_moving_tag "$variant"
}

date_prefix_for_tag() {
  case "$1" in
    kasm|kasm-*) printf 'kasm' ;;
    *) printf '' ;;
  esac
}

# Host path bind-mounted onto /config in deploy/compose.override.yml.
config_bind_path() {
  local line path
  [[ -f "$COMPOSE_OVERRIDE" ]] || return 1
  line=$(grep -E '^[[:space:]]*-[[:space:]]*[^[:space:]]+:/config([[:space:]:]|$)' "$COMPOSE_OVERRIDE" | tail -n 1 || true)
  [[ -n "$line" ]] || return 1
  path=$(printf '%s\n' "$line" | sed -n 's/^[[:space:]]*-[[:space:]]*\([^:]*\):\/config.*/\1/p')
  [[ -n "$path" ]] || return 1
  printf '%s' "$path"
}

suggested_puid() {
  local path uid
  if path=$(config_bind_path) && [[ -e "$path" ]]; then
    uid=$(stat -c '%u' "$path")
    if [[ -n "$uid" && "$uid" != "0" ]]; then
      printf '%s' "$uid"
      return
    fi
  fi
  if [[ -n "${SUDO_UID:-}" && "${SUDO_UID}" != "0" ]]; then
    printf '%s' "${SUDO_UID}"
    return
  fi
  uid=$(id -u)
  if [[ "$uid" != "0" ]]; then
    printf '%s' "$uid"
    return
  fi
  printf '1000'
}

suggested_pgid() {
  local path gid
  if path=$(config_bind_path) && [[ -e "$path" ]]; then
    gid=$(stat -c '%g' "$path")
    if [[ -n "$gid" && "$gid" != "0" ]]; then
      printf '%s' "$gid"
      return
    fi
  fi
  if [[ -n "${SUDO_GID:-}" && "${SUDO_GID}" != "0" ]]; then
    printf '%s' "${SUDO_GID}"
    return
  fi
  gid=$(id -g)
  if [[ "$gid" != "0" ]]; then
    printf '%s' "$gid"
    return
  fi
  printf '1000'
}

root_id_problem() {
  local puid pgid
  puid=$(env_get PUID)
  pgid=$(env_get PGID)
  [[ "$puid" == "0" || "$pgid" == "0" ]]
}

warn_root_ids() {
  root_id_problem || return 0
  err "PUID=$(env_get PUID) PGID=$(env_get PGID)"
  err "0 이면 abc 가 root 가 됩니다. 세션이 root 로 뜨고, /config 소유자가 root 가 되며, VLC 는 'not supposed to be run as root' 로 종료합니다."
  err "deploy/.env 의 PUID 와 PGID 를 $(suggested_puid)/$(suggested_pgid) 로 바꾸세요."
}

# Interactive start offers to rewrite 0. Noninteractive start refuses.
filebrowser_enabled() {
  local value
  value=$(env_get FILEBROWSER)
  value=${value,,}
  [[ "$value" == "on" || "$value" == "true" || "$value" == "1" || "$value" == "yes" ]]
}

filebrowser_noauth_value() {
  local value
  value=$(env_get FILEBROWSER_NOAUTH)
  value=${value,,}
  case "$value" in
    1|true|yes|on) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

apply_config_source() {
  local configured bind
  configured=$(env_get WEBTOP_CONFIG_SOURCE)
  if [[ -n "$configured" ]]; then
    export WEBTOP_CONFIG_SOURCE="$configured"
    return 0
  fi
  if bind=$(config_bind_path); then
    export WEBTOP_CONFIG_SOURCE="$bind"
  fi
}

ensure_filebrowser_data_dir() {
  local dir uid gid
  dir="$ROOT/deploy/filebrowser-data"
  uid=$(env_get PUID)
  gid=$(env_get PGID)
  uid=${uid:-1000}
  gid=${gid:-1000}
  if [[ "$uid" == "0" || "$gid" == "0" ]]; then
    return 0
  fi
  mkdir -p "$dir/tmp"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${uid}:${gid}" "$dir"
  elif [[ "$(stat -c '%u' "$dir")" != "$uid" ]]; then
    warn "deploy/filebrowser-data 소유자를 ${uid}:${gid} 로 맞추세요."
  fi
}

offer_fix_root_ids() {
  local answer uid gid
  root_id_problem || return 0
  warn_root_ids
  uid=$(suggested_puid)
  gid=$(suggested_pgid)
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    err "비대화형 모드에서는 PUID/PGID 0 으로 시작하지 않습니다."
    return 1
  fi
  answer=$(prompt "PUID/PGID 를 ${uid}/${gid} 로 바꾸고 계속할까요? (Y/n)" "Y")
  if [[ "$answer" == "n" || "$answer" == "N" ]]; then
    err "시작을 취소했습니다."
    return 1
  fi
  if [[ "$(env_get PUID)" == "0" ]]; then
    env_set PUID "$uid" || return 1
  fi
  if [[ "$(env_get PGID)" == "0" ]]; then
    env_set PGID "$gid" || return 1
  fi
  ok "PUID=$(env_get PUID) PGID=$(env_get PGID) 로 저장했습니다. webtop 을 다시 만들어야 적용됩니다."
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
    info "변형: $(env_get WEBTOP_VARIANT)  이미지 태그: $(env_get IMAGE_TAG)"
    warn_root_ids || true
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
    if [[ -z "$puid" || "$puid" == "0" ]]; then
      [[ "$puid" == "0" ]] && warn "PUID 0 은 데스크톱을 root 로 만듭니다. $(suggested_puid) 을 사용합니다."
      puid=$(suggested_puid)
    fi
    pgid=${OPT_PGID:-$(env_get PGID)}
    if [[ -z "$pgid" || "$pgid" == "0" ]]; then
      [[ "$pgid" == "0" ]] && warn "PGID 0 은 데스크톱을 root 로 만듭니다. $(suggested_pgid) 을 사용합니다."
      pgid=$(suggested_pgid)
    fi
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
    if [[ -z "$current" || "$current" == "0" ]]; then
      [[ "$current" == "0" ]] && warn "저장된 PUID 가 0 입니다. root 세션에서는 VLC 가 뜨지 않습니다."
      current=$(suggested_puid)
    fi
    puid=$(prompt "PUID" "$current")
    current=$(env_get PGID)
    if [[ -z "$current" || "$current" == "0" ]]; then
      [[ "$current" == "0" ]] && warn "저장된 PGID 가 0 입니다. root 세션에서는 VLC 가 뜨지 않습니다."
      current=$(suggested_pgid)
    fi
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
  if [[ "$puid" == "0" || "$pgid" == "0" ]]; then
    err "PUID 와 PGID 는 0 일 수 없습니다. 세션이 root 가 되고 VLC 가 시작을 거부합니다. $(suggested_puid) 을 사용하세요."
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

  local variant prev_variant moving current_tag
  prev_variant=$(env_get WEBTOP_VARIANT)
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    if [[ -n "$OPT_VARIANT" ]]; then
      if ! variant=$(normalize_variant "$OPT_VARIANT"); then
        err "변형은 selkies 또는 kasm 이어야 합니다."
        return 1
      fi
    else
      if ! variant=$(normalize_variant "${prev_variant:-selkies}"); then
        err "WEBTOP_VARIANT 값이 올바르지 않습니다: ${prev_variant}"
        return 1
      fi
    fi
  else
    local variant_default
    variant_default=$(normalize_variant "${prev_variant:-selkies}" || true)
    variant_default=${variant_default:-selkies}
    variant=$(prompt "데스크톱 변형 (selkies=KDE, kasm=XFCE)" "$variant_default")
    if ! variant=$(normalize_variant "$variant"); then
      err "변형은 selkies 또는 kasm 이어야 합니다."
      return 1
    fi
  fi

  env_set MAXMIND_ACCOUNT_ID "$account" || return 1
  env_set MAXMIND_LICENSE_KEY "$license" || return 1
  env_set ALLOWED_COUNTRIES "$countries" || return 1
  env_set PUID "$puid" || return 1
  env_set PGID "$pgid" || return 1
  env_set TZ "$tz" || return 1
  env_set HTTPS_PORT "$https" || return 1
  env_set HTTP_PORT "$http" || return 1
  env_set WEBTOP_VARIANT "$variant" || return 1
  moving=$(variant_moving_tag "$variant")
  current_tag=$(env_get IMAGE_TAG)
  if [[ -z "$current_tag" || "$current_tag" == "latest" || "$current_tag" == "kasm" || "${prev_variant:-selkies}" != "$variant" ]]; then
    env_set IMAGE_TAG "$moving" || return 1
  fi
  ensure_proxy_secret || return 1
  ok "deploy/.env 를 저장했습니다. 라이선스 키는 출력하지 않습니다."
  info "  계정 ID=${account}  국가=${countries}  PUID=${puid}  PGID=${pgid}  TZ=${tz}"
  info "  HTTPS=${https}  HTTP=${http:-끔}"
  info "  변형=${variant}  이미지 태그=$(env_get IMAGE_TAG)"
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
  local -a args=()
  local -a parts=()
  local raw item
  if ca_exists; then
    if [[ ${#OPT_CONSTRAINTS[@]} -gt 0 ]]; then
      err "CA가 이미 있습니다. 이름 제약은 인증서 안에 고정되어 있어 바꾸지 않습니다."
      err "CA를 교체하면 서버 인증서와 모든 클라이언트 인증서를 다시 발급하고, 각 기기의 루트 CA 도 지운 뒤 다시 설치해야 합니다."
      return 1
    fi
    ok "CA가 이미 있습니다: ${CERT_DIR}/ca/ca.crt"
    return 0
  fi
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    for item in "${OPT_CONSTRAINTS[@]}"; do
      args+=(--name-constraint "$item")
    done
  else
    warn "이름 제약은 선택입니다. 비우면 이 CA 는 어떤 이름에도 서명할 수 있습니다."
    warn "도메인이나 IP 를 넣으면 그 이름만 서명할 수 있는 critical nameConstraints 가 CA 에 들어갑니다."
    warn "도메인 제약은 그 이름과 하위 이름을 허용합니다. 서버 인증서 SAN 이 제약 밖이면 브라우저가 인증서를 거절합니다."
    warn "기본 서버 SAN 에는 localhost 와 127.0.0.1 이 포함됩니다. 도메인만 제약하면 그 둘은 검증에 실패합니다."
    warn "나중에 CA 를 바꾸면 서버 인증서와 모든 클라이언트 인증서를 다시 발급하고, 기기에 설치한 루트를 지우고 다시 설치해야 합니다."
    raw=$(prompt "허용할 도메인 또는 IP (쉼표로 여러 개, 없으면 Enter)" "")
    IFS=',' read -r -a parts <<<"$raw"
    for item in "${parts[@]}"; do
      item=${item//[[:space:]]/}
      [[ -z "$item" ]] && continue
      args+=(--name-constraint "$item")
    done
  fi
  "$GEN_CERTS" init "${args[@]}"
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
    if [[ -z "$name" ]]; then
      err "장치 이름이 필요합니다. 예: ./webtop.sh client laptop"
      return 1
    fi
    if [[ -z "$pass" ]]; then
      info "비밀번호를 비워 두어 임의로 만듭니다. 한 번만 표시합니다."
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
  local log rc shown_pass p12_out p12_dir
  local -a extra_args=()
  if [[ "$OPT_ADMIN" -eq 1 || "$FORCE_ADMIN" -eq 1 ]]; then
    extra_args+=(--admin)
  fi
  p12_out=""
  if [[ "$OPT_KEEP" -eq 1 ]]; then
    extra_args+=(--keep)
  else
    p12_dir=$(mktemp -d "${TMPDIR:-/tmp}/webtop-${name}.XXXXXX")
    p12_out="${p12_dir}/${name}.p12"
  fi
  log=$(mktemp)
  if [[ -n "$p12_out" ]]; then
    CLIENT_P12_OUT="$p12_out" P12_PASS="$pass" "$GEN_CERTS" client "$name" "${extra_args[@]}" >"$log" 2>&1
  else
    P12_PASS="$pass" "$GEN_CERTS" client "$name" "${extra_args[@]}" >"$log" 2>&1
  fi
  rc=$?
  shown_pass=$(sed -n 's/^PKCS#12 password: //p' "$log" | tail -n 1)
  grep -v '^PKCS#12 password:' "$log" || true
  rm -f "$log"
  if [[ "$rc" -ne 0 ]]; then
    if [[ -n "$p12_out" ]]; then
      rm -rf "$(dirname "$p12_out")"
    fi
    err "클라이언트 인증서 발급에 실패했습니다."
    return 1
  fi
  ok "발급했습니다."
  info "  인증서  ${CERT_DIR}/clients/${name}.crt"
  if [[ "$OPT_KEEP" -eq 1 ]]; then
    warn "개인키가 서버에 남습니다: ${CERT_DIR}/clients/${name}.p12"
  else
    info "  PKCS#12 ${p12_out}"
    info "개인키 파일은 서버 인증서 보관함에 남기지 않았습니다. 기기로 옮긴 뒤 ${p12_out} 을 지우세요."
  fi
  if [[ -n "$shown_pass" ]]; then
    info "PKCS#12 비밀번호는 이번 한 번만 표시합니다."
    printf '%s\n' "$shown_pass"
  fi
}

cmd_admin_client() {
  FORCE_ADMIN=1
  cmd_client
  local rc=$?
  FORCE_ADMIN=0
  return "$rc"
}

access_base() {
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
    printf 'https://%s' "$host"
  else
    printf 'https://%s:%s' "$host" "$port"
  fi
}

enroll_default_minutes() {
  local raw min
  raw=$(env_get ENROLL_TTL_SECONDS)
  raw=${raw:-600}
  if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
    raw=600
  fi
  min=$((raw / 60))
  if [[ "$min" -lt 1 ]]; then
    min=1
  fi
  if [[ "$min" -gt 1440 ]]; then
    min=1440
  fi
  printf '%s' "$min"
}

cmd_enroll() {
  local name minutes base running
  local -a py
  require_env_file || return 1
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    name=${OPT_NAME:-}
    minutes=${OPT_MINUTES:-}
  else
    name=$(prompt "장치 이름 (없으면 Enter)" "")
    minutes=$(prompt "유효 시간(분, 비우면 ENROLL_TTL_SECONDS)" "$(enroll_default_minutes)")
  fi
  if [[ -n "$minutes" && ! "$minutes" =~ ^[0-9]+$ ]]; then
    err "분은 숫자여야 합니다."
    return 1
  fi
  running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -x 'webtop-certadmin' || true)
  if [[ -z "$running" ]]; then
    err "certadmin 이 실행 중이 아닙니다. 스택을 시작하세요."
    return 1
  fi
  base=$(access_base)
  py=(python -u /app/certadmin.py enroll)
  if [[ -n "$minutes" ]]; then
    py+=(--minutes "$minutes")
  fi
  if [[ -n "$name" ]]; then
    py+=(--name "$name")
  fi
  compose exec -T -e "PUBLIC_BASE_URL=${base}" certadmin "${py[@]}"
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
  offer_fix_root_ids || return 1
  compose up -d --build
  show_access_url
}

cmd_stop() {
  require_env_file || return 1
  compose stop
}

cmd_restart() {
  require_env_file || return 1
  if root_id_problem; then
    offer_fix_root_ids || return 1
    info "바뀐 PUID/PGID 를 적용하려고 webtop 을 다시 만듭니다."
    compose up -d --no-deps --force-recreate webtop
    return 0
  fi
  compose restart
}

version_script_rev() {
  local sha date
  if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi
  sha=$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || true)
  date=$(git -C "$ROOT" log -1 --format=%cs 2>/dev/null || true)
  if [[ -z "$sha" || -z "$date" ]]; then
    printf 'unknown'
    return 0
  fi
  printf '%s (%s)' "$sha" "$date"
}

version_variant() {
  local raw variant
  raw=$(env_get WEBTOP_VARIANT)
  if ! variant=$(normalize_variant "${raw:-selkies}"); then
    printf 'unknown'
    return 0
  fi
  printf '%s' "${variant:-selkies}"
}

version_cache_word() {
  local repo image
  if [[ ! -f "$(login_cache_file)" ]]; then
    printf '확인 안 됨'
    return 0
  fi
  repo=$(login_cache_get repo)
  image=$(login_cache_get image)
  if [[ "$repo" == "behind" || "$repo" == "dirty" || "$image" == "behind" ]]; then
    printf '업데이트 있음'
    return 0
  fi
  if [[ "$repo" == "current" && "$image" == "current" ]]; then
    printf '최신'
    return 0
  fi
  printf '확인 안 됨'
}

version_short_digest() {
  local ref=$1 hex
  hex=${ref##*sha256:}
  hex=${hex%%[^0-9a-fA-F]*}
  if [[ ${#hex} -ge 8 ]]; then
    printf 'image sha256:%s' "${hex:0:8}"
    return 0
  fi
  printf 'not running'
}

version_image_field() {
  local running id repo
  if ! have docker; then
    printf 'not running'
    return 0
  fi
  running=$(docker inspect -f '{{.State.Running}}' webtop 2>/dev/null || true)
  if [[ "$running" != "true" ]]; then
    printf 'not running'
    return 0
  fi
  id=$(docker inspect -f '{{.Image}}' webtop 2>/dev/null || true)
  repo=""
  if [[ -n "$id" ]]; then
    repo=$(docker image inspect "$id" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)
  fi
  if [[ -n "$repo" && "$repo" != "<no value>" ]]; then
    version_short_digest "$repo"
    return 0
  fi
  version_short_digest "$id"
}

version_label_value() {
  local key=$1 value
  value=$(docker inspect -f "{{index .Config.Labels \"${key}\"}}" webtop 2>/dev/null || true)
  value=${value//$'\r'/}
  case "$value" in
    ""|"<no value>"|null) printf '' ;;
    *) printf '%s' "$value" ;;
  esac
}

version_line() {
  info "webtop $(version_script_rev) · $(version_variant) · $(version_image_field) · $(version_cache_word)"
}

version_image_meta() {
  local rev created
  [[ "$(version_image_field)" == "not running" ]] && return 0
  rev=$(version_label_value org.opencontainers.image.revision)
  created=$(version_label_value org.opencontainers.image.created)
  [[ -n "$rev" || -n "$created" ]] || return 0
  if [[ "$rev" =~ ^[0-9a-fA-F]{7,}$ ]]; then
    rev=${rev:0:7}
  fi
  info "image revision ${rev:-unknown} · created ${created:-unknown}"
}

cmd_version() {
  if [[ "$OPT_CHECK" -eq 1 ]]; then
    cmd_login_refresh || true
  fi
  version_line
  version_image_meta
}

cmd_status() {
  version_line
  require_env_file || return 1
  warn_root_ids || true
  compose ps
}

ipv4_private() {
  awk -v ip="$1" 'BEGIN {
    n = split(ip, o, ".")
    if (n != 4) exit 1
    for (i = 1; i <= 4; i++) if (o[i] !~ /^[0-9]+$/ || o[i] > 255) exit 1
    v = o[1] * 16777216 + o[2] * 65536 + o[3] * 256 + o[4]
    if (o[1] == 0 || o[1] == 10 || o[1] == 127) exit 0
    if (o[1] == 169 && o[2] == 254) exit 0
    if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) exit 0
    if (o[1] == 192 && o[2] == 168) exit 0
    exit 1
  }'
}

ip_is_private() {
  local ip=$1
  if [[ "$ip" == *:* ]]; then
    local low=${ip,,}
    [[ "$low" == "::1" || "$low" == fc* || "$low" == fd* || "$low" == fe80:* ]]
    return $?
  fi
  ipv4_private "$ip"
}

valid_ip() {
  [[ "$1" =~ ^[0-9A-Fa-f:.]+$ ]]
}

nginx_container() {
  docker inspect -f '{{.State.Running}}' webtop-nginx >/dev/null 2>&1
}

cmd_geo_status() {
  have docker || { err "docker 가 없습니다."; return 1; }
  if ! nginx_container; then
    err "webtop-nginx 가 실행 중이 아닙니다. 스택을 시작한 뒤 다시 보세요."
    return 1
  fi
  local mode allowed db
  mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' webtop-nginx)
  allowed=$(docker exec webtop-nginx printenv ALLOWED_COUNTRIES 2>/dev/null || true)
  db=$(docker exec webtop-nginx printenv GEOIP_DB 2>/dev/null || true)
  db=${db:-/usr/share/GeoIP/GeoLite2-Country.mmdb}
  info "네트워크 모드: ${mode}"
  info "허용 국가: ${allowed:-KR,JP}"
  info "판정은 access.log 의 client= 주소에 MaxMind 가 붙인 국가입니다. VPN 앱의 가상 위치 이름과 다를 수 있습니다."
  info "DB: ${db}"
  docker exec webtop-nginx sh -c "ls -l \"$db\"; echo size=\$(wc -c < \"$db\")" || return 1
  if have python3; then
    docker exec webtop-nginx cat "$db" | python3 "$ROOT/scripts/mmdb-meta.py" || true
  else
    warn "python3 가 없어 DB 빌드 시각은 생략합니다."
  fi
  if docker inspect webtop-geoipupdate >/dev/null 2>&1; then
    info "geoipupdate 최근 로그:"
    docker logs --tail 15 webtop-geoipupdate 2>&1 || true
  else
    warn "webtop-geoipupdate 컨테이너가 없습니다."
  fi
  local stream="$ROOT/deploy/logs/stream.log"
  if [[ -r "$stream" ]]; then
    info "최근 거부 (stream.log allowed=0):"
    grep 'allowed=0' "$stream" | tail -n 10 || info "  없음"
  else
    warn "stream 로그를 읽을 수 없습니다: ${stream}"
  fi
}

cmd_geo_test() {
  local ip=${OPT_NAME:-}
  have docker || { err "docker 가 없습니다."; return 1; }
  if [[ -z "$ip" ]]; then
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      err "IP 가 필요합니다. 예: ./webtop.sh geo-test 175.139.0.1"
      return 1
    fi
    ip=$(prompt "검사할 IP" "")
  fi
  if ! valid_ip "$ip"; then
    err "IP 형식이 올바르지 않습니다: ${ip}"
    return 1
  fi
  if ! nginx_container; then
    err "webtop-nginx 가 실행 중이 아닙니다."
    return 1
  fi
  local allowed raw country decision reason
  allowed=$(docker exec webtop-nginx printenv ALLOWED_COUNTRIES 2>/dev/null || echo "KR,JP")
  allowed=${allowed:-KR,JP}
  raw=$(docker exec webtop-nginx mmdblookup --file /usr/share/GeoIP/GeoLite2-Country.mmdb --ip "$ip" country iso_code 2>&1) || true
  country=$(printf '%s\n' "$raw" | sed -n 's/.*"\([A-Za-z][A-Za-z]\)".*/\1/p' | head -n 1)
  country=$(printf '%s' "$country" | tr '[:lower:]' '[:upper:]')
  if ip_is_private "$ip"; then
    decision=ALLOW
    reason="사설/루프백/링크로컬 대역"
  elif [[ -z "$country" ]]; then
    decision=DROP
    reason="DB에 국가가 없습니다. 알 수 없는 주소는 거부합니다."
  elif printf ',%s,' "$allowed" | tr '[:lower:]' '[:upper:]' | grep -q ",${country},"; then
    decision=ALLOW
    reason="허용 목록 ${allowed}"
  else
    decision=DROP
    reason="국가 ${country} 는 허용 목록 ${allowed} 에 없습니다"
  fi
  info "IP ${ip}"
  info "MaxMind 국가: ${country:-없음}"
  info "VPN 앱이 보여주는 가상 위치와 다를 수 있습니다. 필터는 그 이름이 아니라 MaxMind 가 이 IP 에 부여한 국가로 판단합니다."
  info "allowed_countries ${allowed}"
  if [[ "$decision" == "ALLOW" ]]; then
    ok "decision ALLOW (${reason})"
  else
    err "decision DROP (${reason})"
  fi
  [[ "$decision" == "ALLOW" ]]
}

ask_tty() {
  local label=$1 default=$2 reply
  if [[ "$NONINTERACTIVE" -eq 1 || ! -r /dev/tty ]]; then
    printf '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$label" "$default" >/dev/tty
  else
    printf '%s: ' "$label" >/dev/tty
  fi
  IFS= read -r reply </dev/tty || true
  printf '%s' "${reply:-$default}"
}

service_container() {
  case "$1" in
    webtop) printf '%s' webtop ;;
    nginx) printf '%s' webtop-nginx ;;
    geoipupdate) printf '%s' webtop-geoipupdate ;;
    certadmin) printf '%s' webtop-certadmin ;;
    filebrowser) printf '%s' webtop-filebrowser ;;
    *) return 1 ;;
  esac
}

# 0 running, 1 stopped, 2 missing, 3 docker unreachable
inspect_container() {
  local name=$1 err
  INSPECT_STATE=""
  INSPECT_ERR=""
  err=$(mktemp)
  if ! INSPECT_STATE=$(docker inspect -f '{{.State.Running}}' "$name" 2>"$err"); then
    INSPECT_ERR=$(cat "$err")
    rm -f "$err"
    if grep -qi 'permission denied\|Cannot connect' <<<"$INSPECT_ERR"; then
      return 3
    fi
    return 2
  fi
  rm -f "$err"
  if [[ "$INSPECT_STATE" == "true" ]]; then
    return 0
  fi
  return 1
}

explain_docker_failure() {
  local name=$1 state=$2
  case "$state" in
    3)
      err "Docker 에 연결하지 못했습니다. 소켓 권한을 확인하세요."
      [[ -n "$INSPECT_ERR" ]] && printf '%s\n' "$INSPECT_ERR" >&2
      ;;
    2)
      err "스택이 실행 중이 아닙니다. 컨테이너가 없습니다: ${name}"
      err "먼저 ./webtop.sh start 로 스택을 시작하세요."
      ;;
    1)
      err "컨테이너가 중지되어 있습니다: ${name}"
      err "위는 중지 전까지의 로그입니다. 따라가지 않습니다."
      ;;
  esac
}

run_interruptible() {
  local interrupted=0
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    "$@"
    return $?
  fi
  info "최근 ${LOG_TAIL}줄부터 표시합니다. Ctrl+C 를 누르면 메뉴로 돌아갑니다."
  trap 'interrupted=1' INT
  "$@" || true
  trap on_int INT
  [[ "$interrupted" -eq 1 ]] && printf '\n'
  return 0
}

show_container_logs() {
  local svc=$1 name state follow=0
  name=$(service_container "$svc") || return 1
  inspect_container "$name"
  state=$?
  if [[ "$state" -eq 2 || "$state" -eq 3 ]]; then
    explain_docker_failure "$name" "$state"
    return 1
  fi
  if [[ "$NONINTERACTIVE" -eq 0 && -t 1 && "$state" -eq 0 ]]; then
    follow=1
  fi
  if [[ "$follow" -eq 1 ]]; then
    run_interruptible docker logs --tail "$LOG_TAIL" -f "$name"
  else
    docker logs --tail "$LOG_TAIL" "$name" || return 1
    if [[ "$state" -eq 1 ]]; then
      explain_docker_failure "$name" 1
      return 1
    fi
  fi
  return 0
}

show_all_logs() {
  local svc name state found=0 running=0 spec
  local -a follow=()
  for svc in webtop nginx geoipupdate certadmin filebrowser; do
    name=$(service_container "$svc")
    inspect_container "$name"
    state=$?
    if [[ "$state" -eq 3 ]]; then
      explain_docker_failure "$name" 3
      return 1
    fi
    if [[ "$state" -eq 2 ]]; then
      continue
    fi
    found=1
    if [[ "$state" -eq 0 ]]; then
      running=1
      follow+=("${svc}|${name}")
    else
      info "[$svc] ${name} (중지됨)"
      docker logs --tail "$LOG_TAIL" "$name" || true
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    err "스택이 실행 중이 아닙니다. webtop, webtop-nginx, webtop-geoipupdate, webtop-certadmin 컨테이너가 없습니다."
    err "먼저 ./webtop.sh start 로 스택을 시작하세요."
    return 1
  fi
  if [[ "$NONINTERACTIVE" -eq 1 || ! -t 1 || "$running" -eq 0 ]]; then
    for spec in "${follow[@]}"; do
      info "[${spec%%|*}] ${spec#*|}"
      docker logs --tail "$LOG_TAIL" "${spec#*|}" || true
    done
    if [[ "$running" -eq 0 ]]; then
      err "실행 중인 컨테이너가 없어 로그를 따라가지 않습니다."
      return 1
    fi
    return 0
  fi
  info "최근 ${LOG_TAIL}줄부터 표시합니다. Ctrl+C 를 누르면 메뉴로 돌아갑니다."
  local interrupted=0 monitor=0 psvc pname
  local -a pids=()
  [[ $- == *m* ]] && monitor=1
  set -m
  trap 'interrupted=1' INT
  for spec in "${follow[@]}"; do
    psvc=${spec%%|*}
    pname=${spec#*|}
    docker logs --tail "$LOG_TAIL" -f "$pname" 2>&1 | awk -v p="[${psvc}] " '{ print p $0; fflush() }' &
    pids+=("$!")
  done
  while [[ "$interrupted" -eq 0 ]]; do
    wait -n || true
    if ! jobs -r >/dev/null 2>&1; then
      break
    fi
    jobs -r | grep -q . || break
  done
  trap on_int INT
  if [[ ${#pids[@]} -gt 0 ]]; then
    kill "${pids[@]}" 2>/dev/null || true
  fi
  wait || true
  [[ "$monitor" -eq 0 ]] && set +m
  [[ "$interrupted" -eq 1 ]] && printf '\n'
  return 0
}

apply_profile_env() {
  local profile=$1
  env_set WEBTOP_PROFILE "$profile" || return 1
  case "$profile" in
    low-power)
      env_set SELKIES_ENCODER jpeg || return 1
      env_set SELKIES_FRAMERATE 30 || return 1
      env_set SELKIES_JPEG_QUALITY 55 || return 1
      env_set SELKIES_VIDEO_CRF 32 || return 1
      env_set SELKIES_USE_CPU true || return 1
      env_set SELKIES_CPU_ENCODE_THREADING true || return 1
      env_set SELKIES_VIDEO_STREAMING_MODE false || return 1
      env_set SELKIES_USE_CSS_SCALING true || return 1
      env_set SELKIES_SCALING_DPI 96 || return 1
      env_set WEBTOP_BRAVE_LOW_CPU 1 || return 1
      ;;
    balanced)
      env_set SELKIES_ENCODER h264enc || return 1
      env_set SELKIES_FRAMERATE 30 || return 1
      env_set SELKIES_JPEG_QUALITY 70 || return 1
      env_set SELKIES_VIDEO_CRF 28 || return 1
      env_set SELKIES_USE_CPU true || return 1
      env_set SELKIES_CPU_ENCODE_THREADING true || return 1
      env_set SELKIES_VIDEO_STREAMING_MODE false || return 1
      env_set SELKIES_USE_CSS_SCALING false || return 1
      env_set SELKIES_SCALING_DPI 96 || return 1
      env_set WEBTOP_BRAVE_LOW_CPU 1 || return 1
      ;;
    quality)
      env_set SELKIES_ENCODER h264enc || return 1
      env_set SELKIES_FRAMERATE 60 || return 1
      env_set SELKIES_JPEG_QUALITY 80 || return 1
      env_set SELKIES_VIDEO_CRF 23 || return 1
      env_set SELKIES_USE_CPU true || return 1
      env_set SELKIES_CPU_ENCODE_THREADING true || return 1
      env_set SELKIES_VIDEO_STREAMING_MODE false || return 1
      env_set SELKIES_USE_CSS_SCALING false || return 1
      env_set SELKIES_SCALING_DPI 120 || return 1
      env_set WEBTOP_BRAVE_LOW_CPU 0 || return 1
      ;;
  esac
  if [[ -z "$(env_get SELKIES_AUDIO_ENABLED)" ]]; then
    env_set SELKIES_AUDIO_ENABLED true || return 1
  fi
}

cmd_variant() {
  local name=${OPT_VARIANT:-${OPT_NAME:-}} variant tag
  require_env_file || return 1
  if [[ -z "$name" ]]; then
    info "현재 변형: $(env_get WEBTOP_VARIANT)  이미지 태그: $(env_get IMAGE_TAG)"
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      return 0
    fi
    name=$(prompt "변형 (selkies/kasm)" "$(env_get WEBTOP_VARIANT)")
  fi
  if ! variant=$(normalize_variant "$name"); then
    err "변형은 selkies 또는 kasm 이어야 합니다."
    return 1
  fi
  tag=$(variant_moving_tag "$variant")
  env_set WEBTOP_VARIANT "$variant" || return 1
  env_set IMAGE_TAG "$tag" || return 1
  ok "변형을 ${variant} 로 저장했습니다. 이미지 태그=${tag}"
  if [[ "$variant" == "kasm" ]]; then
    info "KasmVNC + XFCE 입니다. /config 는 Selkies 와 같이 씁니다."
    info "성능 프로파일은 적용되지 않습니다. 첫 클릭이나 키 입력 때 브라우저 소리가 켜집니다."
  else
    info "Selkies + KDE 입니다. 이미지 태그는 latest 입니다."
  fi
  if ! have docker; then
    warn "docker 가 없어 컨테이너는 다시 만들지 않았습니다."
    return 0
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx webtop; then
    info "webtop 컨테이너를 새 이미지로 다시 만듭니다."
    compose pull webtop
    compose up -d --no-deps --force-recreate webtop
  else
    info "webtop 이 꺼져 있습니다. 다음에 시작할 때 적용됩니다."
  fi
}

write_bash_completion() {
  local name=$1 dir=/etc/bash_completion.d file
  file="${dir}/webtop"
  if [[ ! -d "$dir" ]] && ! mkdir -p "$dir"; then
    warn "bash 완료 디렉터리를 만들지 못했습니다: ${dir}"
    return 0
  fi
  cat >"$file" <<EOF
# Installed by webtop link. Completes the ${name} command.
_webtop_complete() {
  local cur
  cur="\${COMP_WORDS[COMP_CWORD]}"
  if [[ \${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=( \$(compgen -W "precheck env ca server client enroll list revoke start stop restart status logs access access-log geo-status geo-test profile variant filebrowser self-update upgrade update check-update auto-update cron-install cron-remove cron-status install link motd login-check version" -- "\$cur") )
  fi
}
complete -F _webtop_complete ${name}
EOF
  ok "bash 완료를 설치했습니다: ${file}"
  info "현재 셸에 적용하려면 source ${file}"
}

cmd_link() {
  local name=${OPT_NAME:-webtop} dest
  if ! valid_name "$name"; then
    err "링크 이름은 영문, 숫자, ., _, - 만 사용할 수 있습니다."
    return 1
  fi
  dest="/usr/local/bin/${name}"
  if [[ "$(id -u)" -ne 0 ]]; then
    err "이 링크는 root 가 필요합니다."
    err "예: sudo ${SCRIPT_PATH} link ${name}"
    return 1
  fi
  if [[ ! -d /usr/local/bin ]]; then
    err "디렉터리가 없습니다: /usr/local/bin"
    return 1
  fi
  ln -sfn "$SCRIPT_PATH" "$dest"
  ok "링크를 만들었습니다: ${dest} -> ${SCRIPT_PATH}"
  write_bash_completion "$name"
  cmd_login_install || true
}

cmd_filebrowser() {
  local action=${OPT_NAME:-} line
  require_env_file || return 1
  case "$action" in
    on)
      offer_fix_root_ids || return 1
      env_set FILEBROWSER on || return 1
      ensure_filebrowser_data_dir || return 1
      ok "파일 브라우저를 켰습니다. 주소는 /fi/ 입니다."
      info "로그인은 켜 둡니다. 처음 비밀번호는 ./webtop.sh filebrowser password"
      info "/files/ 는 Kasm 웹 클라이언트의 파일 관리자입니다. Quantum 으로 보내지 않습니다."
      if ! have docker; then
        warn "docker 가 없어 컨테이너는 시작하지 않았습니다."
        return 0
      fi
      compose up -d --no-deps --build nginx
      compose up -d --no-deps --force-recreate filebrowser
      ;;
    off)
      env_set FILEBROWSER off || return 1
      ok "파일 브라우저를 껐습니다. /fi/ 는 502 입니다."
      if ! have docker; then
        return 0
      fi
      compose --with-filebrowser rm -sf filebrowser || true
      ;;
    status)
      if filebrowser_enabled; then
        info "설정: 켜짐"
      else
        info "설정: 꺼짐"
      fi
      info "자체 로그인 끄기(FILEBROWSER_NOAUTH)=$(filebrowser_noauth_value)"
      apply_config_source
      if [[ -n "${WEBTOP_CONFIG_SOURCE:-}" ]]; then
        info "데이터 원본: ${WEBTOP_CONFIG_SOURCE}"
      else
        info "데이터 원본: webtop-config 볼륨"
      fi
      if have docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx webtop-filebrowser; then
        docker ps -a --filter name=^webtop-filebrowser$ --format '컨테이너: {{.Status}}'
      else
        info "컨테이너: 없음"
      fi
      ;;
    password)
      have docker || { err "docker 가 없습니다."; return 1; }
      line=$(docker logs webtop-filebrowser 2>&1 | grep -i 'initial admin password' | tail -n 1 || true)
      if [[ -z "$line" ]]; then
        err "로그에서 초기 관리자 비밀번호를 찾지 못했습니다."
        err "컨테이너가 방금 켜졌으면 잠시 뒤 다시 실행하세요. 이미 바꾼 비밀번호는 로그에 없습니다."
        return 1
      fi
      printf '%s\n' "$line"
      info "아이디는 admin 입니다. 첫 로그인 때 비밀번호를 바꿉니다."
      ;;
    *)
      err "사용법: ./webtop.sh filebrowser on|off|status|password"
      return 1
      ;;
  esac
}

cmd_profile() {
  local profile=${OPT_PROFILE:-${OPT_NAME:-}}
  require_env_file || return 1
  ensure_variant_env || return 1
  if [[ "$(env_get WEBTOP_VARIANT)" == "kasm" ]]; then
    warn "성능 프로파일은 Selkies 전용입니다. 현재 변형은 KasmVNC XFCE 라 인코더와 프레임을 바꾸지 않습니다."
    info "Brave GPU 래스터는 WEBTOP_BRAVE_LOW_CPU 로 조절합니다. 현재 값: $(env_get WEBTOP_BRAVE_LOW_CPU)"
    return 0
  fi
  if [[ -z "$profile" ]]; then
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      err "프로파일이 필요합니다. 예: ./webtop.sh profile low-power"
      return 1
    fi
    info "현재 프로파일: $(env_get WEBTOP_PROFILE)"
    profile=$(prompt "프로파일 (low-power/balanced/quality)" "low-power")
  fi
  case "$profile" in
    low|low-power) profile="low-power" ;;
    balanced|quality) ;;
    *)
      err "프로파일은 low-power, balanced, quality 중 하나여야 합니다."
      return 1
      ;;
  esac
  apply_profile_env "$profile" || return 1
  ok "성능 프로파일을 ${profile} 로 저장했습니다."
  info "  인코더=$(env_get SELKIES_ENCODER)  프레임=$(env_get SELKIES_FRAMERATE)  소리=$(env_get SELKIES_AUDIO_ENABLED)"
  if ! have docker; then
    warn "docker 가 없어 컨테이너는 다시 만들지 않았습니다."
    return 0
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx webtop; then
    info "webtop 컨테이너를 다시 만들어 환경 변수를 적용합니다."
    compose up -d --no-deps --force-recreate webtop
  else
    info "webtop 이 꺼져 있습니다. 다음에 시작할 때 적용됩니다."
  fi
}

cmd_logs() {
  local svc=${OPT_SERVICE:-}
  have docker || { err "docker 가 없습니다."; return 1; }
  if [[ -z "$svc" ]]; then
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      svc=all
    else
      svc=$(ask_tty "서비스 (webtop/nginx/geoipupdate/certadmin/all)" "nginx")
    fi
  fi
  case "$svc" in
    webtop|nginx|geoipupdate|certadmin|filebrowser) show_container_logs "$svc" ;;
    all) show_all_logs ;;
    *)
      err "서비스는 webtop, nginx, geoipupdate, certadmin, filebrowser, all 중 하나여야 합니다."
      return 1
      ;;
  esac
}

format_access_line() {
  local line=$1 time country cn status method uri
  time=${line%% *}
  country="-"; cn="-"; status="-"; method="-"; uri="-"
  [[ "$line" =~ country=\"([^\"]*)\" ]] && country=${BASH_REMATCH[1]}
  [[ "$line" =~ cn=\"([^\"]*)\" ]] && cn=${BASH_REMATCH[1]}
  [[ "$line" =~ status=([0-9]+) ]] && status=${BASH_REMATCH[1]}
  [[ "$line" =~ method=([A-Z]+) ]] && method=${BASH_REMATCH[1]}
  [[ "$line" =~ uri=\"([^\"]*)\" ]] && uri=${BASH_REMATCH[1]}
  if [[ "$status" == "-" ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  printf '%s  country=%s  cn=%s  %s %s  status=%s\n' \
    "$time" "$country" "$cn" "$method" "$uri" "$status"
}

format_certadmin_line() {
  local line=$1 ts _ip country admin action name _serial result
  IFS=$'\t' read -r ts _ip country admin action name _serial result <<<"$line"
  if [[ -z "$action" ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  printf '%s  country=%s  admin=%s  %s  name=%s  %s\n' \
    "$ts" "${country:--}" "${admin:--}" "$action" "${name:--}" "${result:--}"
}

log_kind_path() {
  case "$1" in
    access|nginx) printf '%s' "$ACCESS_LOG" ;;
    certadmin|audit) printf '%s' "$CERTADMIN_LOG" ;;
    update) printf '%s' "$UPDATE_LOG" ;;
    *) return 1 ;;
  esac
}

stream_log_file() {
  local kind=$1 path=$2 line
  if [[ ! -f "$path" ]]; then
    err "로그 파일이 없습니다: ${path}"
    if [[ "$kind" == "access" || "$kind" == "nginx" ]]; then
      inspect_container webtop-nginx
      case $? in
        0) err "webtop-nginx 는 실행 중이지만 아직 이 경로에 기록을 남기지 않았습니다." ;;
        1) err "webtop-nginx 컨테이너가 중지되어 있습니다." ;;
        2) err "스택이 실행 중이 아닙니다. webtop-nginx 컨테이너가 없습니다." ;;
        3) explain_docker_failure webtop-nginx 3 ;;
      esac
    fi
    return 1
  fi
  if [[ ! -s "$path" ]]; then
    warn "로그 파일이 비어 있습니다: ${path}"
  fi
  if [[ "$NONINTERACTIVE" -eq 1 || ! -t 1 ]]; then
    while IFS= read -r line; do
      case "$kind" in
        access|nginx) format_access_line "$line" ;;
        certadmin|audit) format_certadmin_line "$line" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < <(tail -n "$LOG_TAIL" "$path")
    return 0
  fi
  info "파일: ${path}"
  info "최근 ${LOG_TAIL}줄부터 표시합니다. Ctrl+C 를 누르면 메뉴로 돌아갑니다."
  local interrupted=0
  trap 'interrupted=1' INT
  tail -n "$LOG_TAIL" -f "$path" | while IFS= read -r line; do
    case "$kind" in
      access|nginx) format_access_line "$line" ;;
      certadmin|audit) format_certadmin_line "$line" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done || true
  trap on_int INT
  [[ "$interrupted" -eq 1 ]] && printf '\n'
  return 0
}

cmd_access() {
  local kind=${OPT_NAME:-}
  if [[ -z "$kind" ]]; then
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      kind=access
    else
      kind=$(ask_tty "로그 (access/certadmin/update)" "access")
    fi
  fi
  local path
  path=$(log_kind_path "$kind") || {
    err "로그 종류는 access, certadmin, update 중 하나여야 합니다."
    return 1
  }
  stream_log_file "$kind" "$path"
}

host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) printf '' ;;
  esac
}

http_get() {
  if [[ "${WEBTOP_LOGIN_REFRESH:-}" == "1" ]]; then
    curl --max-time "${WEBTOP_LOGIN_HTTP_TIMEOUT:-10}" "$@"
  else
    curl "$@"
  fi
}

ghcr_token() {
  local body
  body=$(http_get -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:krsuhjunho/webtop:pull") || return 1
  printf '%s' "$body" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

ghcr_manifest() {
  local token=$1 ref=$2 accept=$3
  http_get -fsSL \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: ${accept}" \
    "https://ghcr.io/v2/krsuhjunho/webtop/manifests/${ref}"
}

ghcr_digest_header() {
  local token=$1 ref=$2
  http_get -fsSL -D - -o /dev/null \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://ghcr.io/v2/krsuhjunho/webtop/manifests/${ref}" \
    | awk 'BEGIN { IGNORECASE = 1 } tolower($1)=="docker-content-digest:" { print $2; exit }' \
    | tr -d '\r'
}

remote_release() {
  local token arch index_json arch_digest manifest tag prefix
  token=$(ghcr_token) || return 1
  [[ -n "$token" ]] || return 1
  arch=$(host_arch)
  [[ -n "$arch" ]] || { err "지원하지 않는 아키텍처입니다: $(uname -m)"; return 1; }
  tag=$(image_tag_for_update)
  [[ -n "$tag" ]] || return 1
  REMOTE_TAG=$tag
  IMAGE_REF="${IMAGE_NAME}:${tag}"
  index_json=$(ghcr_manifest "$token" "$tag" "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json") || return 1
  REMOTE_INDEX=$(ghcr_digest_header "$token" "$tag")
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
  if [[ "${WEBTOP_LOGIN_REFRESH:-}" == "1" ]]; then
    REMOTE_DATE=""
    return 0
  fi
  prefix=$(date_prefix_for_tag "$tag")
  REMOTE_DATE=$(date_tag_for_index "$token" "$REMOTE_INDEX" "$prefix")
}

date_tag_for_index() {
  local token=$1 want=$2 prefix=${3:-} tags tag digest pattern
  local -a patterns=()
  tags=$(http_get -fsSL -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/krsuhjunho/webtop/tags/list") || return 0
  if [[ "$prefix" == "kasm" ]]; then
    patterns=('kasm-[0-9]{6}')
  else
    patterns=('[0-9]{6}' 'kasm-[0-9]{6}')
  fi
  for pattern in "${patterns[@]}"; do
    for tag in $(printf '%s' "$tags" | grep -oE "\"${pattern}\"" | tr -d '"'); do
      digest=$(ghcr_digest_header "$token" "$tag") || continue
      if [[ "$digest" == "$want" ]]; then
        printf '%s' "$tag"
        return 0
      fi
    done
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
  info "원격 ${REMOTE_TAG:-latest} ($(host_arch)): ${remote_id}"
  info "원격 매니페스트: ${REMOTE_ARCH}  날짜 태그: ${REMOTE_DATE:-없음}"
}

note_update() {
  mkdir -p "$(dirname "$UPDATE_LOG")"
  printf '%s %s\n' "$(date -Is)" "$*" >>"$UPDATE_LOG"
  info "$*"
}

self_update_enabled() {
  local value
  value=$(env_get SELF_UPDATE)
  value=${value:-on}
  value=${value,,}
  [[ "$value" == "on" || "$value" == "true" || "$value" == "1" || "$value" == "yes" ]]
}

repo_is_git() {
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

git_repo() {
  git -C "$ROOT" "$@"
}

tracked_local_changes() {
  git_repo status --porcelain --untracked-files=no
}

rebuild_pulled_services() {
  local before=$1 after=$2 files nginx=0 cert=0
  local -a svcs=()
  [[ "$before" == "$after" ]] && return 0
  files=$(git_repo diff --name-only "$before" "$after")
  if printf '%s\n' "$files" | grep -qE '^(deploy/nginx/|deploy/docker-compose\.yml$|deploy/compose\.http\.yml$|deploy/compose\.override\.yml$)'; then
    nginx=1
  fi
  if printf '%s\n' "$files" | grep -qE '^(deploy/certadmin/|deploy/docker-compose\.yml$|deploy/compose\.http\.yml$|deploy/compose\.override\.yml$)'; then
    cert=1
  fi
  [[ "$nginx" -eq 0 && "$cert" -eq 0 ]] && return 0
  if ! have docker; then
    note_update "docker 가 없어 nginx/certadmin 을 다시 만들지 않았습니다."
    return 0
  fi
  if [[ "$nginx" -eq 1 ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx webtop-nginx; then
    svcs+=(nginx)
  fi
  if [[ "$cert" -eq 1 ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx webtop-certadmin; then
    svcs+=(certadmin)
  fi
  if [[ ${#svcs[@]} -eq 0 ]]; then
    note_update "nginx 또는 certadmin 설정이 바뀌었습니다. 스택이 없어 다음에 시작할 때 적용됩니다."
    return 0
  fi
  note_update "다시 만듭니다: ${svcs[*]}"
  compose up -d --build --no-deps "${svcs[@]}"
}

maybe_reexec_after_pull() {
  local before=$1 after=$2 next_step=$3 files
  files=$(git_repo diff --name-only "$before" "$after")
  if printf '%s\n' "$files" | grep -qx 'webtop.sh' && [[ "${WEBTOP_REEXECED:-}" != "1" ]]; then
    note_update "새 webtop.sh 로 이어서 실행합니다."
    export WEBTOP_REEXECED=1
    export WEBTOP_PULL_BEFORE=$before
    export WEBTOP_PULL_AFTER=$after
    export WEBTOP_AFTER_PULL=$next_step
    exec "$SCRIPT_PATH" __after-pull
  fi
}

cmd_after_pull() {
  local before=${WEBTOP_PULL_BEFORE:-} after=${WEBTOP_PULL_AFTER:-} next_step=${WEBTOP_AFTER_PULL:-self} update_rc=0
  [[ -n "$before" && -n "$after" ]] || { err "가져온 커밋 범위가 없습니다."; return 1; }
  rebuild_pulled_services "$before" "$after" || return 1
  if [[ "$next_step" == "auto" ]]; then
    OPT_YES=1
    cmd_update || update_rc=$?
  fi
  if [[ "${WEBTOP_LOGIN_APPLY:-}" == "1" ]]; then
    WEBTOP_LOGIN_REFRESH=1 cmd_login_refresh || true
  fi
  return "$update_rc"
}

# 0 current, 10 behind and fast-forwardable, 1 blocked or error.
cmd_repo_check() {
  local dirty behind ahead branch line
  have git || { err "git 이 없습니다."; return 1; }
  if ! repo_is_git; then
    warn "git 저장소가 아닙니다: ${ROOT}"
    return 1
  fi
  note_update "저장소 ${ROOT} 에서 origin/main 을 가져옵니다."
  if ! login_git_fetch; then
    err "git fetch origin main 에 실패했습니다."
    return 1
  fi
  if ! git_repo rev-parse --verify --quiet origin/main >/dev/null; then
    err "origin/main 이 없습니다."
    return 1
  fi
  dirty=$(tracked_local_changes || true)
  if [[ -n "$dirty" ]]; then
    warn "추적 중인 파일에 로컬 변경이 있습니다. 버리지 않습니다."
    printf '%s\n' "$dirty"
  fi
  branch=$(git_repo rev-parse --abbrev-ref HEAD)
  behind=$(git_repo rev-list --count HEAD..origin/main)
  ahead=$(git_repo rev-list --count origin/main..HEAD)
  if [[ "$behind" == "0" && "$ahead" == "0" ]]; then
    ok "저장소는 origin/main 과 같습니다."
    return 0
  fi
  if [[ "$ahead" != "0" && "$behind" != "0" ]]; then
    err "로컬 ${branch} 가 origin/main 과 갈라져 있습니다. fast-forward 하지 않습니다."
    return 1
  fi
  if [[ "$ahead" != "0" ]]; then
    warn "로컬 ${branch} 에 origin/main 에 없는 커밋이 ${ahead}개 있습니다. 덮어쓰지 않습니다."
    return 1
  fi
  note_update "origin/main 이 ${behind} 커밋 앞섭니다."
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    note_update "  $line"
  done < <(git_repo log --oneline HEAD..origin/main)
  if [[ "$branch" != "main" ]]; then
    err "현재 브랜치는 ${branch} 입니다. main 에서만 fast-forward 합니다."
    return 1
  fi
  if [[ -n "$dirty" ]]; then
    return 2
  fi
  return 10
}

cmd_self_update() {
  local next_step=${1:-self} rc=0 before after answer
  if [[ "${WEBTOP_SKIP_SELF_UPDATE:-}" == "1" ]]; then
    return 0
  fi
  cmd_repo_check || rc=$?
  if [[ "$OPT_CHECK" -eq 1 || "$next_step" == "check" ]]; then
    if [[ "$rc" -eq 10 || "$rc" -eq 2 ]]; then
      note_update "check 모드라 저장소를 적용하지 않습니다."
      return 10
    fi
    return "$rc"
  fi
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$rc" -eq 2 ]]; then
    if [[ "$OPT_STASH" -eq 1 ]]; then
      note_update "추적 파일의 로컬 변경을 stash 합니다. 추적되지 않은 파일은 그대로입니다."
      git_repo stash push -m "webtop self-update" || return 1
      ok "stash 했습니다. 끝난 뒤 git -C ${ROOT} stash pop 으로 되돌리세요."
    else
      err "로컬 변경이 있어 fast-forward 하지 않습니다. --stash 로 잠시 넣거나 직접 정리하세요."
      return 1
    fi
  elif [[ "$rc" -ne 10 ]]; then
    return "$rc"
  fi
  if [[ "$NONINTERACTIVE" -eq 1 && "$OPT_YES" -ne 1 ]]; then
    err "저장소를 적용하려면 --yes 를 붙이세요."
    return 10
  fi
  if [[ "$NONINTERACTIVE" -eq 0 && "$OPT_YES" -ne 1 ]]; then
    answer=$(prompt "저장소를 fast-forward 할까요? (y/N)" "N")
    [[ "$answer" == "y" || "$answer" == "Y" ]] || { info "취소했습니다."; return 0; }
  fi
  before=$(git_repo rev-parse HEAD)
  if ! GIT_TERMINAL_PROMPT=0 git_repo pull --ff-only origin main; then
    err "git pull --ff-only origin main 에 실패했습니다."
    return 1
  fi
  after=$(git_repo rev-parse HEAD)
  note_update "저장소를 ${before} 에서 ${after} 로 맞췄습니다."
  maybe_reexec_after_pull "$before" "$after" "$next_step"
  rebuild_pulled_services "$before" "$after"
}

login_git_fetch() {
  if [[ "${WEBTOP_LOGIN_REFRESH:-}" == "1" ]] && have timeout; then
    GIT_TERMINAL_PROMPT=0 timeout 20 git -C "$ROOT" fetch origin main
  else
    GIT_TERMINAL_PROMPT=0 git_repo fetch origin main
  fi
}

login_check_mode() {
  local value
  value=$(env_get LOGIN_CHECK)
  value=${value:-prompt}
  value=${value,,}
  case "$value" in
    off|false|0|no) printf 'off' ;;
    notify|notice) printf 'notify' ;;
    *) printf 'prompt' ;;
  esac
}

login_show_version() {
  local value
  value=$(env_get LOGIN_SHOW_VERSION)
  value=${value:-on}
  value=${value,,}
  case "$value" in
    off|false|0|no) return 1 ;;
    *) return 0 ;;
  esac
}

login_interval_seconds() {
  local raw
  raw=$(env_get LOGIN_CHECK_INTERVAL)
  raw=${raw:-6}
  if [[ "$raw" =~ ^[0-9]+$ && "$raw" -gt 0 ]]; then
    printf '%s' $((raw * 3600))
  else
    printf '21600'
  fi
}

login_prompt_seconds() {
  local raw
  raw=$(env_get LOGIN_CHECK_TIMEOUT)
  raw=${raw:-15}
  if [[ "$raw" =~ ^[0-9]+$ && "$raw" -gt 0 ]]; then
    printf '%s' "$raw"
  else
    printf '15'
  fi
}

login_cache_file() {
  local dir
  if [[ -n "${WEBTOP_LOGIN_CACHE:-}" ]]; then
    printf '%s' "$WEBTOP_LOGIN_CACHE"
    return 0
  fi
  dir="$ROOT/deploy/logs"
  if { [[ -d "$dir" && -w "$dir" ]] || mkdir -p "$dir" 2>/dev/null; } && [[ -w "$dir" ]]; then
    printf '%s' "$dir/login-check.cache"
    return 0
  fi
  dir="${HOME:-/tmp}/.cache/webtop"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "$dir/login-check"
}

login_cache_get() {
  local key=$1 file line
  file=$(login_cache_file)
  [[ -f "$file" ]] || return 0
  line=$(grep -E "^${key}=" "$file" | tail -n 1 || true)
  printf '%s' "${line#"${key}"=}"
}

login_session_ok() {
  [[ "${WEBTOP_LOGIN_ASSUME_INTERACTIVE:-}" == "1" ]] && return 0
  [[ -t 0 && -t 1 ]] || return 1
  return 0
}

login_can_git() {
  have git || return 1
  repo_is_git || return 1
  [[ -w "$ROOT/.git" || -w "$ROOT" ]]
}

login_can_docker() {
  have docker || return 1
  [[ "$(id -u)" -eq 0 || -w /var/run/docker.sock ]]
}

login_command_name() {
  if have webtop; then
    printf 'webtop'
  else
    printf '%s' "$SCRIPT_PATH"
  fi
}

login_suggest_command() {
  local repo=$1 image=$2 bin text=""
  bin=$(login_command_name)
  if [[ "$repo" == "behind" ]]; then
    text="${bin} self-update --yes"
  elif [[ "$repo" == "dirty" ]]; then
    text="${bin} self-update --stash --yes"
  fi
  if [[ "$image" == "behind" ]]; then
    if [[ -n "$text" ]]; then
      text="${text} && ${bin} update --yes"
    else
      text="${bin} update --yes"
    fi
  fi
  printf '%s' "$text"
}

login_can_apply() {
  local repo image
  repo=$(login_cache_get repo)
  image=$(login_cache_get image)
  if [[ "$repo" == "behind" ]] && ! login_can_git; then
    return 1
  fi
  if [[ "$image" == "behind" ]] && ! login_can_docker; then
    return 1
  fi
  # A dirty checkout is not fast-forwarded from the login prompt.
  if [[ "$repo" == "dirty" ]]; then
    return 1
  fi
  [[ "$repo" == "behind" || "$image" == "behind" ]]
}

login_skip_active() {
  local now fp key until
  fp=$(login_cache_get fingerprint)
  key=$(login_cache_get skip_key)
  until=$(login_cache_get skip_until)
  [[ -n "$fp" && "$key" == "$fp" ]] || return 1
  [[ "$until" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  (( now < until ))
}

login_write_cache() {
  local file tmp now fp repo_state=$1 repo_tip=$2 image_state=$3 image_id=$4 tag=$5
  local skip_key=${6-} skip_until=${7-}
  file=$(login_cache_file)
  mkdir -p "$(dirname "$file")" || return 0
  now=$(date +%s)
  fp="${repo_tip}:${image_id}"
  if [[ -z "$skip_key" && "$(login_cache_get fingerprint)" == "$fp" ]]; then
    skip_key=$(login_cache_get skip_key)
    skip_until=$(login_cache_get skip_until)
  fi
  skip_until=${skip_until:-0}
  tmp=$(mktemp "${file}.XXXXXX")
  cat >"$tmp" <<EOF
checked_at=${now}
repo=${repo_state}
repo_tip=${repo_tip}
image=${image_state}
image_id=${image_id}
tag=${tag}
fingerprint=${fp}
skip_key=${skip_key}
skip_until=${skip_until}
EOF
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

login_remember_skip() {
  local fp now until file tmp key line
  file=$(login_cache_file)
  [[ -f "$file" ]] || return 0
  fp=$(login_cache_get fingerprint)
  [[ -n "$fp" ]] || return 0
  now=$(date +%s)
  until=$((now + $(login_interval_seconds)))
  tmp=$(mktemp "${file}.XXXXXX")
  while IFS= read -r line || [[ -n "$line" ]]; do
    key=${line%%=*}
    case "$key" in
      skip_key) printf 'skip_key=%s\n' "$fp" ;;
      skip_until) printf 'skip_until=%s\n' "$until" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$file" >"$tmp"
  if ! grep -q '^skip_key=' "$tmp"; then
    printf 'skip_key=%s\nskip_until=%s\n' "$fp" "$until" >>"$tmp"
  fi
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

login_cache_stale() {
  local checked now interval
  [[ -f "$(login_cache_file)" ]] || return 0
  checked=$(login_cache_get checked_at)
  [[ "$checked" =~ ^[0-9]+$ ]] || return 0
  now=$(date +%s)
  interval=$(login_interval_seconds)
  (( now - checked >= interval ))
}

login_spawn_refresh() {
  if have timeout; then
    nohup timeout 60 "$SCRIPT_PATH" login-check refresh >/dev/null 2>&1 &
  else
    nohup "$SCRIPT_PATH" login-check refresh >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true
}

login_image_status() {
  have docker || return 1
  remote_release || return 1
  collect_local_image
  if images_current; then
    return 0
  fi
  return 10
}

cmd_login_refresh() {
  local repo_rc=0 image_rc=0 repo_state=unknown repo_tip="" image_state=unknown image_id="" tag lock
  export WEBTOP_LOGIN_REFRESH=1
  lock="$(login_cache_file).lock"
  mkdir -p "$(dirname "$lock")" || return 0
  if have flock; then
    exec 7>>"$lock"
    if ! flock -n 7; then
      return 0
    fi
  fi
  if cmd_repo_check >/dev/null 2>&1; then
    repo_rc=0
  else
    repo_rc=$?
  fi
  case "$repo_rc" in
    0)
      repo_state=current
      repo_tip=$(git_repo rev-parse HEAD 2>/dev/null || true)
      ;;
    10)
      repo_state=behind
      repo_tip=$(git_repo rev-parse origin/main 2>/dev/null || true)
      ;;
    2)
      repo_state=dirty
      repo_tip=$(git_repo rev-parse origin/main 2>/dev/null || true)
      ;;
    *)
      repo_state=unknown
      ;;
  esac
  tag=$(image_tag_for_update 2>/dev/null || true)
  if login_image_status >/dev/null 2>&1; then
    image_rc=0
  else
    image_rc=$?
  fi
  case "$image_rc" in
    0)
      image_state=current
      image_id=${REMOTE_CONFIG:-}
      ;;
    10)
      image_state=behind
      image_id=${REMOTE_CONFIG:-}
      ;;
    *)
      image_state=unknown
      ;;
  esac
  login_write_cache "$repo_state" "$repo_tip" "$image_state" "$image_id" "$tag"
}

login_notice() {
  if [[ -t 1 ]]; then
    printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF"
  else
    printf '%s\n' "$*"
  fi
}

login_print_pending() {
  local repo=$1 image=$2 tag=$3
  if [[ "$repo" == "behind" ]]; then
    login_notice "webtop 저장소 업데이트가 있습니다."
  elif [[ "$repo" == "dirty" ]]; then
    login_notice "webtop 저장소 업데이트가 있지만 추적 파일에 로컬 변경이 있습니다."
  fi
  if [[ "$image" == "behind" ]]; then
    login_notice "webtop 이미지 업데이트가 있습니다 (${tag:-latest})."
  fi
}

cmd_login_apply() {
  local repo image
  repo=$(login_cache_get repo)
  image=$(login_cache_get image)
  OPT_YES=1
  export WEBTOP_LOGIN_APPLY=1
  if [[ "$repo" == "behind" ]] && login_can_git; then
    cmd_self_update auto || true
  fi
  if [[ "${WEBTOP_LOGIN_APPLY:-}" == "1" && "$image" == "behind" ]] && login_can_docker; then
    OPT_YES=1
    cmd_update || true
  fi
  if [[ "${WEBTOP_LOGIN_APPLY:-}" == "1" ]]; then
    WEBTOP_LOGIN_REFRESH=1 cmd_login_refresh || true
  fi
}

cmd_login_show() {
  local mode repo image tag suggestion reply timeout pending=0
  login_session_ok || return 0
  mode=$(login_check_mode)
  if [[ "$mode" != "off" ]] && login_cache_stale; then
    login_spawn_refresh
  fi
  repo=$(login_cache_get repo)
  image=$(login_cache_get image)
  if [[ "$mode" != "off" && ( "$repo" == "behind" || "$repo" == "dirty" || "$image" == "behind" ) ]]; then
    pending=1
  fi
  if [[ "$pending" -eq 1 ]] || login_show_version; then
    version_line
  fi
  [[ "$pending" -eq 1 ]] || return 0
  tag=$(login_cache_get tag)
  login_print_pending "$repo" "$image" "$tag"
  suggestion=$(login_suggest_command "$repo" "$image")
  if [[ "$mode" != "prompt" ]] || ! login_can_apply || login_skip_active; then
    [[ -n "$suggestion" ]] && info "나중에 실행: ${suggestion}"
    return 0
  fi
  timeout=$(login_prompt_seconds)
  reply=""
  printf '업데이트를 지금 진행할까요? [Y/n] '
  if ! read -t "$timeout" -r reply; then
    printf '\n'
    [[ -n "$suggestion" ]] && info "나중에 실행: ${suggestion}"
    login_remember_skip
    return 0
  fi
  case "${reply,,}" in
    ""|y|yes)
      printf '\n'
      cmd_login_apply || true
      ;;
    *)
      [[ -n "$suggestion" ]] && info "나중에 실행: ${suggestion}"
      login_remember_skip
      ;;
  esac
  return 0
}

login_profile_path() {
  if [[ -n "${WEBTOP_LOGIN_PROFILE:-}" ]]; then
    printf '%s' "$WEBTOP_LOGIN_PROFILE"
    return 0
  fi
  printf '/etc/profile.d/webtop-update.sh'
}

login_bashrc_path() {
  if [[ -n "${WEBTOP_LOGIN_BASHRC:-}" ]]; then
    printf '%s' "$WEBTOP_LOGIN_BASHRC"
    return 0
  fi
  printf '%s/.bashrc' "${HOME:-/tmp}"
}

login_hook_script() {
  cat <<EOF
# webtop-login-check
# Sourced from a login shell. Never fail the login.
if [ -n "\${WEBTOP_LOGIN_SHOWN:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
case \$- in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac
if [ ! -t 0 ] || [ ! -t 1 ]; then
  return 0 2>/dev/null || exit 0
fi
export WEBTOP_LOGIN_SHOWN=1
${SCRIPT_PATH} motd || true
EOF
}

login_write_profile() {
  local file
  file=$(login_profile_path)
  if [[ -e "$file" ]] && ! grep -q 'webtop-login-check' "$file"; then
    warn "로그인 알림을 넣지 않았습니다. 다른 파일입니다: ${file}"
    return 1
  fi
  mkdir -p "$(dirname "$file")" || return 1
  login_hook_script >"$file"
  chmod 644 "$file" 2>/dev/null || true
  ok "로그인 알림을 설치했습니다: ${file}"
}

login_bashrc_has_hook() {
  local file
  file=$(login_bashrc_path)
  [[ -f "$file" ]] && grep -q 'webtop-login-check start' "$file"
}

login_write_bashrc() {
  local file tmp
  file=$(login_bashrc_path)
  mkdir -p "$(dirname "$file")" || return 1
  tmp=$(mktemp)
  if [[ -f "$file" ]]; then
    awk '
      $0 == "# webtop-login-check start" { skip = 1; next }
      $0 == "# webtop-login-check end" { skip = 0; next }
      skip != 1 { print }
    ' "$file" >"$tmp"
  fi
  {
    cat "$tmp"
    printf '%s\n' "# webtop-login-check start"
    login_hook_script
    printf '%s\n' "# webtop-login-check end"
  } >"${tmp}.out"
  mv -f "${tmp}.out" "$file"
  rm -f "$tmp"
  ok "로그인 알림을 넣었습니다: ${file}"
}

login_strip_bashrc() {
  local file tmp
  file=$(login_bashrc_path)
  [[ -f "$file" ]] || return 0
  grep -q 'webtop-login-check' "$file" || return 0
  tmp=$(mktemp)
  awk '
    $0 == "# webtop-login-check start" { skip = 1; next }
    $0 == "# webtop-login-check end" { skip = 0; next }
    skip != 1 { print }
  ' "$file" >"$tmp"
  mv -f "$tmp" "$file"
  ok "로그인 알림을 뺐습니다: ${file}"
}

cmd_login_install() {
  local wrote=0 hours
  hours=$(env_get LOGIN_CHECK_INTERVAL)
  hours=${hours:-6}
  if [[ -n "${WEBTOP_LOGIN_PROFILE:-}" || "$(id -u)" -eq 0 ]]; then
    if login_write_profile; then
      wrote=1
    fi
  fi
  if [[ "$(id -u)" -ne 0 || -n "${WEBTOP_LOGIN_BASHRC:-}" ]]; then
    if [[ "$(id -u)" -ne 0 ]]; then
      login_write_bashrc || return 1
      wrote=1
    elif [[ -n "${WEBTOP_LOGIN_BASHRC:-}" ]]; then
      login_write_bashrc || return 1
      wrote=1
    fi
  fi
  if [[ "$wrote" -eq 0 ]]; then
    err "로그인 알림을 설치하지 못했습니다."
    return 1
  fi
  info "LOGIN_CHECK=$(login_check_mode). 확인 간격은 ${hours}시간입니다. 끄려면 LOGIN_CHECK=off"
}

cmd_login_uninstall() {
  local file removed=0
  file=$(login_profile_path)
  if [[ -f "$file" ]] && grep -q 'webtop-login-check' "$file"; then
    rm -f "$file"
    ok "로그인 알림을 지웠습니다: ${file}"
    removed=1
  fi
  if login_bashrc_has_hook || { [[ -f "$(login_bashrc_path)" ]] && grep -q 'webtop-login-check' "$(login_bashrc_path)"; }; then
    login_strip_bashrc
    removed=1
  fi
  if [[ "$removed" -eq 0 ]]; then
    info "설치된 로그인 알림이 없습니다."
  fi
}

cmd_login_status() {
  local file checked now age
  info "LOGIN_CHECK=$(login_check_mode)"
  info "LOGIN_CHECK_INTERVAL=$(env_get LOGIN_CHECK_INTERVAL)시간 (비우면 6)"
  file=$(login_profile_path)
  if [[ -f "$file" ]] && grep -q 'webtop-login-check' "$file"; then
    ok "프로필: ${file}"
  else
    info "프로필: 없음 (${file})"
  fi
  file=$(login_bashrc_path)
  if [[ -f "$file" ]] && grep -q 'webtop-login-check' "$file"; then
    ok "bashrc: ${file}"
  else
    info "bashrc: 없음 (${file})"
  fi
  file=$(login_cache_file)
  if [[ -f "$file" ]]; then
    checked=$(login_cache_get checked_at)
    now=$(date +%s)
    if [[ "$checked" =~ ^[0-9]+$ ]]; then
      age=$((now - checked))
      info "캐시: ${file}  ${age}초 전  repo=$(login_cache_get repo) image=$(login_cache_get image)"
    else
      info "캐시: ${file}"
    fi
  else
    info "캐시: 아직 없습니다. 다음 로그인에서 백그라운드로 확인합니다."
  fi
}

cmd_login_check() {
  case "${OPT_NAME:-}" in
    install) cmd_login_install ;;
    uninstall|remove) cmd_login_uninstall ;;
    status) cmd_login_status ;;
    refresh) cmd_login_refresh ;;
    "") cmd_login_show ;;
    *)
      err "login-check 는 install, uninstall, status, refresh 입니다."
      return 1
      ;;
  esac
}

cmd_check_update() {
  local part=${1:-all} repo_rc=0
  if [[ "$part" != "image" ]]; then
    cmd_repo_check || repo_rc=$?
    if ! self_update_enabled; then
      info "SELF_UPDATE=off 이라 자동 적용은 하지 않습니다."
    fi
  fi
  have docker || { err "docker 가 없습니다."; return 1; }
  info "원격 이미지를 확인합니다."
  remote_release || { err "GHCR 에서 $(image_tag_for_update) 를 읽지 못했습니다."; return 1; }
  collect_local_image
  report_versions
  if images_current; then
    ok "이미지는 최신입니다."
    if [[ "$repo_rc" -eq 10 || "$repo_rc" -eq 2 ]]; then
      return 10
    fi
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
  offer_fix_root_ids || return 1
  cmd_check_update image
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
    export WEBTOP_FLOCKED=1
  fi
  mode=$(env_get UPDATE_MODE)
  mode=${mode:-check}
  note_update "===== auto-update mode=${mode} self=$(env_get SELF_UPDATE) ====="
  if self_update_enabled; then
    if [[ "$mode" == "apply" ]]; then
      OPT_YES=1
      cmd_self_update auto || true
    else
      cmd_self_update check || true
    fi
  else
    note_update "SELF_UPDATE=off 이라 저장소는 건너뜁니다."
  fi
  if [[ "$mode" == "apply" ]]; then
    OPT_YES=1
    cmd_update
    return $?
  fi
  cmd_check_update image || true
  return 0
}

cron_marker='# webtop-managed'
# Monday 14:00 local, after the image build at Monday 03:17 UTC (12:17 JST).
cron_schedule_default='0 14 * * 1'

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
    "$schedule" "$flock_bin" "$UPDATE_LOCK" "$SCRIPT_PATH" "$UPDATE_LOG"
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
    if [[ ${#OPT_CONSTRAINTS[@]} -gt 0 ]]; then
      cmd_ca || return 1
    fi
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
18) 관리자 인증서 발급
19) 일회용 등록 링크
20) GeoIP 상태
21) GeoIP IP 시험
22) 성능 프로파일
23) 데스크톱 변형
24) 파일 브라우저
25) 스크립트 업데이트
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
    13) OPT_NAME=""; cmd_access || true ;;
    14) cmd_update || true ;;
    15) cmd_install || true ;;
    16) cmd_check_update || true ;;
    17) cmd_cron_menu || true ;;
    18) cmd_admin_client || true ;;
    19) cmd_enroll || true ;;
    20) cmd_geo_status || true ;;
    21) OPT_NAME=""; cmd_geo_test || true ;;
    22) cmd_profile || true ;;
    23) OPT_VARIANT=""; OPT_NAME=""; cmd_variant || true ;;
    24)
      OPT_NAME=""
      if [[ "$NONINTERACTIVE" -eq 0 ]]; then
        OPT_NAME=$(prompt "파일 브라우저 (on/off/status/password)" "status")
      fi
      cmd_filebrowser || true
      ;;
    25) cmd_self_update self || true ;;
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
      --stash) OPT_STASH=1; shift ;;
      --check) OPT_CHECK=1; shift ;;
      --prune) OPT_PRUNE=1; shift ;;
      --admin) OPT_ADMIN=1; shift ;;
      --minutes) OPT_MINUTES=$2; shift 2 ;;
      --cn) OPT_CN=$2; shift 2 ;;
      --extra) OPT_EXTRA=$2; shift 2 ;;
      --name) OPT_NAME=$2; shift 2 ;;
      --name-constraint) OPT_CONSTRAINTS+=("$2"); shift 2 ;;
      --p12-pass) OPT_P12=$2; shift 2 ;;
      --keep) OPT_KEEP=1; shift ;;
      --service) OPT_SERVICE=$2; shift 2 ;;
      --profile) OPT_PROFILE=$2; shift 2 ;;
      --variant) OPT_VARIANT=$2; shift 2 ;;
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
    access|access-log) cmd_access ;;
    geo-status) cmd_geo_status ;;
    geo-test) cmd_geo_test ;;
    update|pull) cmd_update ;;
    check-update) cmd_check_update ;;
    auto-update) cmd_auto_update ;;
    enroll) cmd_enroll ;;
    cron-install) cmd_cron_install ;;
    cron-remove) cmd_cron_remove ;;
    cron-status) cmd_cron_status ;;
    install) cmd_install ;;
    profile) cmd_profile ;;
    variant) cmd_variant ;;
    filebrowser) cmd_filebrowser ;;
    link) cmd_link ;;
    self-update|upgrade) cmd_self_update self ;;
    motd) cmd_login_show ;;
    login-check) cmd_login_check ;;
    version|-v|--version) cmd_version ;;
    __after-pull) cmd_after_pull ;;
    *)
      err "알 수 없는 명령: ${cmd}"
      usage
      return 1
      ;;
  esac
}

main "$@"
