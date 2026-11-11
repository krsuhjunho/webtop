#!/usr/bin/env bash
# Regression: menu logs must not return to the pause prompt with no output.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0

fail() {
  printf 'FAIL %s\n' "$*" >&2
  FAIL=1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/logs"

cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -u
state_dir=${FAKE_DOCKER_STATE:?}
cmd=$1
shift
case "$cmd" in
  inspect)
    name=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f) shift 2 ;;
        *) name=$1; shift ;;
      esac
    done
    if [[ -f "$state_dir/$name.running" ]]; then
      printf 'true\n'
      exit 0
    fi
    if [[ -f "$state_dir/$name.stopped" ]]; then
      printf 'false\n'
      exit 0
    fi
    if [[ -f "$state_dir/docker.down" ]]; then
      echo "permission denied while trying to connect to the Docker daemon socket" >&2
      exit 1
    fi
    echo "Error: No such container: $name" >&2
    exit 1
    ;;
  logs)
    follow=0
    tailn=0
    name=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f) follow=1; shift ;;
        --tail) tailn=$2; shift 2 ;;
        *) name=$1; shift ;;
      esac
    done
    printf 'log %s tail=%s\n' "$name" "$tailn"
    printf 'logs %s follow=%s tail=%s\n' "$name" "$follow" "$tailn" >> "$state_dir/calls"
    if [[ "$follow" -eq 1 ]]; then
      printf 'following %s\n' "$name"
      sleep 60
    fi
    ;;
  *)
    echo "unexpected docker $cmd" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "$tmp/bin/docker"

export PATH="$tmp/bin:$PATH"
export FAKE_DOCKER_STATE="$tmp/state"
export WEBTOP_ACCESS_LOG="$tmp/logs/access.log"
export WEBTOP_CERTADMIN_LOG="$tmp/logs/certadmin.log"
export WEBTOP_UPDATE_LOG="$tmp/logs/update.log"

run_cmd() {
  bash "$ROOT/webtop.sh" "$@"
}

# Missing container is an error that names the container. It must not look like success.
out=$(run_cmd logs nginx 2>&1) && fail "logs nginx exited 0 with no container"
printf '%s\n' "$out" | grep -q 'webtop-nginx' || fail "missing container error did not name webtop-nginx"
printf '%s\n' "$out" | grep -q '실행 중' || fail "missing container error was not explicit"
printf '%s\n' "$out" | grep -q 'log webtop-nginx' && fail "logs ran docker logs without a container"

# Stopped container shows history and says it will not follow.
touch "$tmp/state/webtop-nginx.stopped"
out=$(run_cmd logs nginx 2>&1) && fail "stopped nginx exited 0"
printf '%s\n' "$out" | grep -q 'log webtop-nginx tail=100' || fail "stopped nginx did not print logs"
printf '%s\n' "$out" | grep -q '중지' || fail "stopped nginx did not say it is stopped"
grep -q 'follow=0' "$tmp/state/calls" || fail "noninteractive logs followed"

# Running container, noninteractive: tail, no follow.
rm -f "$tmp/state/calls"
rm -f "$tmp/state/webtop-nginx.stopped"
touch "$tmp/state/webtop-nginx.running"
out=$(run_cmd logs nginx 2>&1) || fail "running nginx logs failed"
printf '%s\n' "$out" | grep -q 'log webtop-nginx tail=100' || fail "running nginx produced no log line"
grep -q 'follow=0' "$tmp/state/calls" || fail "noninteractive running logs followed"
printf '%s\n' "$out" | grep -q 'following' && fail "noninteractive printed a follow banner"

# logs with no service lists every existing container.
touch "$tmp/state/webtop.running" "$tmp/state/webtop-certadmin.running"
out=$(run_cmd logs 2>&1) || fail "logs all failed"
printf '%s\n' "$out" | grep -q 'log webtop tail=100' || fail "logs all missed webtop"
printf '%s\n' "$out" | grep -q 'log webtop-nginx tail=100' || fail "logs all missed nginx"
printf '%s\n' "$out" | grep -q 'log webtop-certadmin tail=100' || fail "logs all missed certadmin"
printf '%s\n' "$out" | grep -q 'webtop-geoipupdate' && fail "logs all mentioned a missing geoip container as if it existed"

# No containers at all.
rm -f "$tmp/state/"*.running "$tmp/state/"*.stopped
out=$(run_cmd logs 2>&1) && fail "logs all with nothing exited 0"
printf '%s\n' "$out" | grep -q 'webtop-nginx' || fail "empty stack error omitted container names"

# Access log formatting and the missing-file error.
sample='2026-11-11T09:00:00+09:00 client=1.2.3.4 country="KR" private=0 cn="laptop" dn="/CN=laptop" serial=10 verify=SUCCESS method=GET uri="/admin/" status=200 bytes=10 ua="x"'
printf '%s\nnot-an-access-line\n' "$sample" > "$tmp/logs/access.log"
out=$(run_cmd access-log 2>&1) || fail "access-log failed"
printf '%s\n' "$out" | grep -q 'country=KR  cn=laptop  GET /admin/  status=200' || fail "access log was not formatted: $out"
printf '%s\n' "$out" | grep -q 'not-an-access-line' || fail "unparsed access line was dropped"
rm -f "$tmp/logs/access.log"
out=$(run_cmd access-log 2>&1) && fail "missing access log exited 0"
printf '%s\n' "$out" | grep -q "$tmp/logs/access.log" || fail "missing access log did not show the path"
printf '%s\n' "$out" | grep -q 'webtop-nginx' || fail "missing access log did not mention the nginx container"

printf '2026-11-11T00:00:00Z\t10.0.0.1\tKR\towner\tissue\tphone\t1003\tok\n' > "$tmp/logs/certadmin.log"
out=$(run_cmd access-log certadmin 2>&1) || fail "certadmin log failed"
printf '%s\n' "$out" | grep -q 'country=KR  admin=owner  issue  name=phone  ok' || fail "certadmin log was not formatted: $out"

printf 'update ran\n' > "$tmp/logs/update.log"
out=$(run_cmd access-log update 2>&1) || fail "update log failed"
printf '%s\n' "$out" | grep -q 'update ran' || fail "update log missing"

out=$(run_cmd access-log nope 2>&1) && fail "bad log kind exited 0"
printf '%s\n' "$out" | grep -q 'access, certadmin, update' || fail "bad log kind had no error"

# Interactive menu: 12 follows until Ctrl+C, then the menu returns.
touch "$tmp/state/webtop-nginx.running"
printf '%s\n' "$sample" > "$tmp/logs/access.log"
python3 - "$ROOT/webtop.sh" <<'PY' || fail "interactive ctrl-c did not return to the menu"
import os, pty, select, sys, time, fcntl, termios
script = sys.argv[1]
master, slave = pty.openpty()
def preexec():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
env = os.environ.copy()
proc = os.fork()
if proc == 0:
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(master)
    os.close(slave)
    preexec()
    os.execvpe("bash", ["bash", script], env)
os.close(slave)
buf = b""
seen = 0
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.1)
        if master in r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
def wait_for(text, sec):
    global seen
    end = time.time() + sec
    needle = text.encode()
    while time.time() < end:
        pump(0.1)
        idx = buf.find(needle, seen)
        if idx >= 0:
            seen = idx + len(needle)
            return True
    sys.stderr.write(buf.decode("utf-8", "replace"))
    return False
if not wait_for("번호:", 3):
    raise SystemExit("no menu")
os.write(master, b"12\n")
if not wait_for("서비스", 3):
    raise SystemExit("no service prompt")
os.write(master, b"nginx\n")
if not wait_for("Ctrl+C", 3):
    raise SystemExit("no ctrl-c hint")
if not wait_for("following webtop-nginx", 3):
    raise SystemExit("did not follow")
os.write(master, b"\x03")
if not wait_for("Enter를 누르면 메뉴로", 3):
    raise SystemExit("ctrl-c did not return to the pause prompt")
os.write(master, b"\n")
if not wait_for("번호:", 3):
    raise SystemExit("ctrl-c did not return to the menu")
os.write(master, b"13\n")
if not wait_for("로그 (access", 3):
    raise SystemExit("no access prompt")
os.write(master, b"\n")
if not wait_for("country=KR", 3):
    raise SystemExit("access follow did not show the formatted line")
os.write(master, b"\x03")
if not wait_for("Enter를 누르면 메뉴로", 3):
    raise SystemExit("access follow ctrl-c did not return")
os.write(master, b"\n")
if not wait_for("번호:", 3):
    raise SystemExit("access follow did not redraw the menu")
os.write(master, b"0\n")
pump(0.5)
os.close(master)
_, status = os.waitpid(proc, 0)
if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0:
    raise SystemExit(0)
raise SystemExit(f"menu exit {status}")
PY

# The access file was removed earlier and recreated before the python test? 
# The python test runs after access-log missing-file test which deleted the file.
# Recreate it before the python block... the python block is above this comment
# and the file was deleted. The test order is wrong if country=KR is required.
# Fixed below if the python section failed for that reason.

if [[ "$FAIL" -ne 0 ]]; then
  printf 'logs menu regression failed\n' >&2
  exit 1
fi
printf 'logs menu regression ok\n'
