#!/usr/bin/env python3
"""Private certificate admin and one-time enrollment. Not published directly."""

import argparse
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import guide

CERT_DIR = os.environ.get("CERT_DIR", "/certs")
LOG_PATH = os.environ.get("LOG_PATH", "/logs/certadmin.log")
ADMIN_CNS = {
    part.strip()
    for part in os.environ.get("ADMIN_CNS", "").split(",")
    if part.strip()
}
PROXY_SECRET = os.environ.get("CERTADMIN_PROXY_SECRET", "")
ENROLL_TTL = int(os.environ.get("ENROLL_TTL_SECONDS", "600"))
NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
LOCK_PATH = os.path.join(CERT_DIR, ".certadmin.lock")
TOKEN_PATH = os.path.join(CERT_DIR, "enroll", "tokens.json")
DUMMY_HASH = "0" * 64
PENDING = {}
STASH_LOCK = threading.Lock()
FAILS = {}
MIN_TTL_SECONDS = 60
MAX_TTL_SECONDS = 1440 * 60


def clamp_ttl_seconds(seconds):
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        seconds = 600
    if seconds < MIN_TTL_SECONDS:
        return MIN_TTL_SECONDS
    if seconds > MAX_TTL_SECONDS:
        return MAX_TTL_SECONDS
    return seconds


def default_ttl_seconds():
    return clamp_ttl_seconds(ENROLL_TTL)

def now():
    return int(time.time())


def audit(action, name, serial, result, ip, country, admin_cn):
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    line = "\t".join(
        [
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            ip or "-",
            country or "-",
            admin_cn or "-",
            action,
            name or "-",
            serial or "-",
            result,
        ]
    )
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


class FileLock:
    def __enter__(self):
        import fcntl

        os.makedirs(CERT_DIR, exist_ok=True)
        self.handle = open(LOCK_PATH, "a+", encoding="utf-8")
        fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, *_args):
        import fcntl

        fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        self.handle.close()


def ensure_layout():
    for sub in ("ca", "server", "clients", "crl", "issued", "enroll"):
        os.makedirs(os.path.join(CERT_DIR, sub), mode=0o700, exist_ok=True)
    index = os.path.join(CERT_DIR, "index.txt")
    if not os.path.exists(index):
        open(index, "a", encoding="utf-8").close()
    attr = os.path.join(CERT_DIR, "index.txt.attr")
    if not os.path.exists(attr):
        with open(attr, "w", encoding="utf-8") as handle:
            handle.write("unique_subject = no\n")
    for name, default in (("serial", "1000\n"), ("crlnumber", "1000\n")):
        path = os.path.join(CERT_DIR, name)
        if not os.path.exists(path):
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(default)
    key = os.path.join(CERT_DIR, "ca", "ca.key")
    if os.path.exists(key):
        os.chmod(key, 0o600)
    write_openssl_cnf()


def write_openssl_cnf():
    text = f"""
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = {CERT_DIR}
certs             = $dir
new_certs_dir     = $dir/issued
database          = $dir/index.txt
serial            = $dir/serial
crlnumber         = $dir/crlnumber
certificate       = $dir/ca/ca.crt
private_key       = $dir/ca/ca.key
default_md        = sha256
default_days      = 825
default_crl_days  = 3650
preserve          = no
policy            = policy_loose
unique_subject    = no

[ policy_loose ]
commonName              = supplied
organizationalUnitName  = optional
organizationName        = optional
countryName             = optional

[ req ]
distinguished_name = dn
string_mask        = utf8only
prompt             = no

[ dn ]
CN = Webtop CA
""".lstrip()
    with open(os.path.join(CERT_DIR, "openssl.cnf"), "w", encoding="utf-8") as handle:
        handle.write(text)


def run(cmd, env=None):
    merged = os.environ.copy()
    if env:
        merged.update(env)
    proc = subprocess.run(cmd, env=merged, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "openssl failed")
    return proc


def ca_ready():
    return os.path.isfile(os.path.join(CERT_DIR, "ca", "ca.key")) and os.path.isfile(
        os.path.join(CERT_DIR, "ca", "ca.crt")
    )


def issue_cert(name, days, password, admin):
    if not NAME_RE.match(name):
        raise ValueError("bad name")
    if not 1 <= days <= 825:
        raise ValueError("bad days")
    if len(password) < 8:
        raise ValueError("bad password")
    crt = os.path.join(CERT_DIR, "clients", f"{name}.crt")
    key = os.path.join(CERT_DIR, "clients", f"{name}.key")
    csr = os.path.join(CERT_DIR, "clients", f"{name}.csr")
    if os.path.exists(crt):
        raise ValueError("exists")
    subject = f"/CN={name}/O=Webtop"
    if admin:
        subject = f"/CN={name}/OU=admin/O=Webtop"
    ext = os.path.join(CERT_DIR, f".{name}.ext")
    signed = False
    with open(ext, "w", encoding="utf-8") as handle:
        handle.write(
            "[client_ext]\n"
            "basicConstraints = CA:FALSE\n"
            "keyUsage = critical, digitalSignature, keyEncipherment\n"
            "extendedKeyUsage = clientAuth\n"
        )
    try:
        run(
            [
                "openssl",
                "req",
                "-new",
                "-nodes",
                "-newkey",
                "rsa:2048",
                "-keyout",
                key,
                "-out",
                csr,
                "-subj",
                subject,
            ]
        )
        os.chmod(key, 0o600)
        run(
            [
                "openssl",
                "ca",
                "-batch",
                "-config",
                os.path.join(CERT_DIR, "openssl.cnf"),
                "-in",
                csr,
                "-out",
                crt,
                "-days",
                str(days),
                "-extfile",
                ext,
                "-extensions",
                "client_ext",
            ]
        )
        signed = True
        pem = subprocess.check_output(["openssl", "x509", "-in", crt])
        with open(crt, "wb") as handle:
            handle.write(pem)
        p12 = subprocess.check_output(
            [
                "openssl",
                "pkcs12",
                "-export",
                "-inkey",
                key,
                "-in",
                crt,
                "-certfile",
                os.path.join(CERT_DIR, "ca", "ca.crt"),
                "-name",
                name,
                "-passout",
                "env:P12_PASS",
            ],
            env={**os.environ, "P12_PASS": password},
        )
    finally:
        for path in (ext, csr, key):
            if os.path.exists(path):
                os.remove(path)
        if not signed and os.path.exists(crt):
            os.remove(crt)
    return p12, serial_of(name)


def serial_of(name):
    latest = ""
    for row in read_index():
        if row["cn"] == name and row["status"] == "V":
            latest = row["serial"]
    return latest


def read_index():
    path = os.path.join(CERT_DIR, "index.txt")
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 6 or not parts[0] or parts[0].startswith("#"):
                continue
            subject = parts[5]
            match = re.search(r"/CN=([^/]+)", subject) or re.search(r"(?:^|,)CN=([^,/]+)", subject)
            cn = match.group(1) if match else ""
            crt = os.path.join(CERT_DIR, "clients", f"{cn}.crt")
            if not cn or not os.path.isfile(crt):
                continue
            rows.append(
                {
                    "status": parts[0],
                    "expiry": parts[1],
                    "serial": parts[3],
                    "subject": subject,
                    "cn": cn,
                    "admin": "OU=admin" in subject,
                }
            )
    return rows


def rewrite_crl():
    tmp = os.path.join(CERT_DIR, "crl", "ca.crl.tmp")
    dest = os.path.join(CERT_DIR, "crl", "ca.crl")
    run(
        [
            "openssl",
            "ca",
            "-config",
            os.path.join(CERT_DIR, "openssl.cnf"),
            "-gencrl",
            "-out",
            tmp,
        ]
    )
    data = open(tmp, "rb").read()
    os.remove(tmp)
    mode = "r+b" if os.path.exists(dest) else "wb"
    with open(dest, mode) as handle:
        handle.seek(0)
        handle.write(data)
        handle.truncate()
    os.chmod(dest, 0o644)


def revoke_name(name):
    crt = os.path.join(CERT_DIR, "clients", f"{name}.crt")
    if not os.path.isfile(crt):
        raise ValueError("missing")
    serial = ""
    for row in read_index():
        if row["cn"] == name and row["status"] == "V":
            serial = row["serial"]
    run(
        [
            "openssl",
            "ca",
            "-config",
            os.path.join(CERT_DIR, "openssl.cnf"),
            "-revoke",
            crt,
            "-crl_reason",
            "keyCompromise",
        ]
    )
    rewrite_crl()
    return serial


def _token_expiry(value):
    try:
        return int(value.get("expires", 0) or 0)
    except (TypeError, ValueError, AttributeError):
        return 0


def load_tokens():
    if not os.path.isfile(TOKEN_PATH):
        return {}
    with open(TOKEN_PATH, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        return {}
    cutoff = now()
    kept = {
        key: value
        for key, value in data.items()
        if isinstance(value, dict) and _token_expiry(value) >= cutoff
    }
    if len(kept) != len(data):
        save_tokens(kept)
    return kept


def save_tokens(data):
    os.makedirs(os.path.dirname(TOKEN_PATH), exist_ok=True)
    tmp = TOKEN_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle)
    os.chmod(tmp, 0o600)
    os.replace(tmp, TOKEN_PATH)


def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_token(name, ttl):
    raw = secrets.token_urlsafe(32)
    digest = token_hash(raw)
    data = load_tokens()
    data[digest] = {
        "hash": digest,
        "expires": now() + ttl,
        "used": False,
        "name": name,
    }
    save_tokens(data)
    return raw


def lookup_token(token):
    digest = token_hash(token)
    data = load_tokens()
    rec = data.get(digest)
    if rec is None:
        hmac.compare_digest(digest, DUMMY_HASH)
        return None, data
    if not hmac.compare_digest(rec.get("hash", ""), digest):
        return None, data
    return rec, data


def public_base():
    configured = os.environ.get("PUBLIC_BASE_URL", "").strip().rstrip("/")
    if configured:
        return configured
    cn = "localhost"
    crt = os.path.join(CERT_DIR, "server", "server.crt")
    if os.path.isfile(crt):
        try:
            text = subprocess.check_output(
                ["openssl", "x509", "-in", crt, "-noout", "-subject"], text=True
            )
            match = re.search(r"CN\s*=\s*([^,/]+)", text)
            if match:
                cn = match.group(1).strip()
        except subprocess.CalledProcessError:
            pass
    port = os.environ.get("HTTPS_PORT", "443")
    if port == "443":
        return f"https://{cn}"
    return f"https://{cn}:{port}"


def stash(payload, filename):
    item_id = secrets.token_urlsafe(24)
    with STASH_LOCK:
        PENDING[item_id] = {"bytes": payload, "filename": filename, "expires": now() + 600}
    return item_id


def take_stash(item_id):
    with STASH_LOCK:
        item = PENDING.pop(item_id, None)
        if item is None:
            return None
        if item["expires"] < now():
            return None
        return item


def too_many_failures(ip):
    window = now() - 600
    hits = [stamp for stamp in FAILS.get(ip, []) if stamp >= window]
    FAILS[ip] = hits
    return len(hits) >= 20


def note_failure(ip):
    FAILS.setdefault(ip, []).append(now())


def esc(value):
    return html.escape(value or "", quote=True)


def page(title, body):
    return (
        "<!DOCTYPE html><html lang='ko'><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        f"<title>{esc(title)}</title><style>"
        "body{font-family:sans-serif;max-width:46rem;margin:1.5rem auto;padding:0 1rem;line-height:1.5}"
        "code{font-family:ui-monospace,monospace;word-break:break-all}"
        ".fp{font-size:1.05rem;background:#f4f4f4;padding:.6rem;border:1px solid #ccc}"
        "details{margin:.4rem 0;border:1px solid #ddd;padding:.4rem .8rem}"
        "summary{cursor:pointer;font-weight:600}"
        "</style>"
        f"<body><h1>{esc(title)}</h1>{body}</body></html>"
    )


def ca_cert_path():
    return os.path.join(CERT_DIR, "ca", "ca.crt")


def load_ca_pem():
    path = ca_cert_path()
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as handle:
        data = handle.read()
    if b"PRIVATE KEY" in data or b"BEGIN CERTIFICATE" not in data:
        return None
    return data


def ca_der(pem):
    return subprocess.check_output(["openssl", "x509", "-outform", "DER"], input=pem)


def ca_fingerprints():
    pem = load_ca_pem()
    if pem is None:
        return "", ""
    der = ca_der(pem)
    sha256 = ":".join(f"{byte:02X}" for byte in hashlib.sha256(der).digest())
    sha1 = ":".join(f"{byte:02X}" for byte in hashlib.sha1(der).digest())
    return sha256, sha1


def ca_block(prefix):
    sha256, sha1 = ca_fingerprints()
    return guide.ca_section(prefix, sha256, sha1)


def install_block(user_agent):
    return guide.install_guide(guide.detect_platform(user_agent))


def enroll_state(token):
    record, _data = lookup_token(token)
    if record is None:
        return "missing", None
    if record.get("expires", 0) < now():
        return "expired", record
    if record.get("used"):
        return "used", record
    return "open", record


def enroll_token_from(path, suffix):
    rest = path[len("/enroll/") :]
    if not rest.endswith(suffix):
        return ""
    token = rest[: -len(suffix)]
    if not token or "/" in token:
        return ""
    return token

class Handler(BaseHTTPRequestHandler):
    server_version = "certadmin"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def client_ip(self):
        return self.headers.get("X-Real-IP", self.client_address[0])

    def country(self):
        return self.headers.get("X-Country", "-") or "-"

    def admin_cn(self):
        return self.headers.get("X-Client-CN", "-") or "-"

    def proxy_ok(self):
        got = self.headers.get("X-Certadmin-Auth", "")
        if not PROXY_SECRET or not hmac.compare_digest(got, PROXY_SECRET):
            self.reply(403, page("거부", "<p>프록시 인증에 실패했습니다.</p>"))
            return False
        return True

    def admin_ok(self):
        if not self.proxy_ok():
            return False
        verify = self.headers.get("X-Client-Verify", "")
        dn = self.headers.get("X-Client-DN", "")
        cn = self.headers.get("X-Client-CN", "")
        allowed = verify == "SUCCESS" and ("OU=admin" in dn or cn in ADMIN_CNS)
        if not allowed:
            audit("deny", cn, "", "forbidden", self.client_ip(), self.country(), cn)
            self.reply(403, page("거부", "<p>관리자 인증서가 필요합니다.</p>"))
            return False
        return True

    def reply(self, status, body, content_type="text/html; charset=utf-8", extra=None):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        if extra:
            for key, value in extra:
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def form(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length > 16384:
            return {}
        raw = self.rfile.read(length).decode("utf-8", "replace")
        parsed = parse_qs(raw, keep_blank_values=True)
        return {key: values[-1] for key, values in parsed.items()}

    def cookie(self, name):
        header = self.headers.get("Cookie", "")
        for part in header.split(";"):
            if "=" not in part:
                continue
            key, value = part.strip().split("=", 1)
            if key == name:
                return value
        return ""

    def csrf_ok(self, form, cookie_name):
        presented = form.get("csrf", "")
        stored = self.cookie(cookie_name)
        if not presented or not stored:
            return False
        return hmac.compare_digest(presented, stored)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/admin/ca.cer", "/admin/ca.crt"):
            self.send_ca(path.endswith(".cer"), admin=True)
            return
        if path == "/admin" or path == "/admin/":
            self.admin_page()
            return
        if path.startswith("/admin/dl/"):
            self.download(path[len("/admin/dl/") :], admin=True)
            return
        if not path.startswith("/enroll"):
            self.reply(404, page("없음", "<p>없는 주소입니다.</p>"))
            return
        if not self.proxy_ok():
            return
        if path.startswith("/enroll/dl/"):
            self.download(path[len("/enroll/dl/") :], admin=False)
            return
        if path in ("/enroll/ca.cer", "/enroll/ca.crt"):
            self.send_ca(path.endswith(".cer"), admin=False, token=self.cookie("enroll_token"))
            return
        if path.startswith("/enroll/") and (path.endswith("/ca.cer") or path.endswith("/ca.crt")):
            suffix = "/ca.cer" if path.endswith("/ca.cer") else "/ca.crt"
            token = enroll_token_from(path, suffix)
            if token:
                self.send_ca(suffix == "/ca.cer", admin=False, token=token)
                return
        if path in ("/enroll", "/enroll/"):
            token = self.cookie("enroll_token")
            if not token:
                self.reply(404, page("없음", "<p>링크가 없습니다.</p>"))
                return
            self.enroll_page(token)
            return
        if path.startswith("/enroll/"):
            token = path[len("/enroll/") :]
            if token and "/" not in token:
                self.redirect_enroll(token)
                return
        self.reply(404, page("없음", "<p>없는 주소입니다.</p>"))

    def do_POST(self):
        path = urlparse(self.path).path
        form = self.form()
        if path == "/admin/issue":
            self.admin_issue(form)
            return
        if path == "/admin/revoke":
            self.admin_revoke(form)
            return
        if path == "/admin/enroll":
            self.admin_enroll(form)
            return
        if path in ("/enroll", "/enroll/"):
            if not self.proxy_ok():
                return
            token = self.cookie("enroll_token")
            if not token:
                self.reply(404, page("없음", "<p>링크가 없습니다.</p>"))
                return
            self.enroll_submit(token, form)
            return
        if path.startswith("/enroll/"):
            token = path[len("/enroll/") :]
            if token and "/" not in token:
                self.enroll_submit(token, form)
                return
        self.reply(404, page("없음", "<p>없는 주소입니다.</p>"))

    def admin_page(self):
        if not self.admin_ok():
            return
        token = secrets.token_urlsafe(32)
        rows = []
        for row in read_index():
            label = {"V": "유효", "R": "폐기", "E": "만료"}.get(row["status"], row["status"])
            rows.append(
                "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
                    esc(row["cn"]),
                    esc(row["serial"]),
                    esc(row["expiry"]),
                    esc(label),
                    "예" if row["admin"] else "",
                )
            )
        body = (
            ca_block("/admin/ca")
            + install_block(self.headers.get("User-Agent", ""))
            + "<table border='1'><tr><th>CN</th><th>시리얼</th><th>만료</th><th>상태</th><th>관리자</th></tr>"
            + "".join(rows)
            + "</table>"
            + "<h2>발급</h2><form method='post' action='/admin/issue'>"
            + f"<input type='hidden' name='csrf' value='{esc(token)}'>"
            + "이름 <input name='name'> 일수 <input name='days' value='30'> "
            + "비밀번호(비우면 생성) <input name='password' type='password'>"
            + "<button>발급</button></form>"
            + "<h2>폐기</h2><form method='post' action='/admin/revoke'>"
            + f"<input type='hidden' name='csrf' value='{esc(token)}'>"
            + "이름 <input name='name'><button>폐기</button></form>"
            + "<h2>등록 링크</h2><form method='post' action='/admin/enroll'>"
            + f"<input type='hidden' name='csrf' value='{esc(token)}'>"
            + "이름(선택) <input name='name'> 분 <input name='minutes' value='{}'>".format(
                default_ttl_seconds() // 60
            )
            + "<button>링크 만들기</button></form>"
        )
        self.reply(
            200,
            page("인증서 관리", body),
            extra=[("Set-Cookie", f"csrf_admin={token}; HttpOnly; Secure; SameSite=Strict; Path=/admin")],
        )

    def admin_issue(self, form):
        if not self.admin_ok():
            return
        if not self.csrf_ok(form, "csrf_admin"):
            self.reply(403, page("거부", "<p>CSRF 확인에 실패했습니다.</p>"))
            return
        name = form.get("name", "")
        try:
            days = int(form.get("days", "30"))
        except ValueError:
            days = 0
        typed = form.get("password", "")
        password = typed or secrets.token_urlsafe(12)
        if typed and len(typed) < 8:
            self.reply(400, page("실패", "<p>비밀번호는 8자 이상이어야 합니다.</p>"))
            return
        admin = form.get("admin", "") == "1"
        try:
            with FileLock():
                ensure_layout()
                p12, serial = issue_cert(name, days, password, admin)
        except Exception:
            audit("issue", name, "", "error", self.client_ip(), self.country(), self.admin_cn())
            self.reply(400, page("실패", "<p>발급하지 못했습니다. 이름과 일수를 확인하세요.</p>"))
            return
        item = stash(p12, f"{name}.p12")
        audit("issue", name, serial, "ok", self.client_ip(), self.country(), self.admin_cn())
        body = (
            f"<p>CN {esc(name)} 시리얼 {esc(serial)}</p>"
            f"<p>비밀번호: <code>{esc(password)}</code></p>"
            f"<p><a href='/admin/dl/{esc(item)}'>PKCS#12 한 번 받기</a></p>"
        )
        self.reply(200, page("발급됨", body))

    def admin_revoke(self, form):
        if not self.admin_ok():
            return
        if not self.csrf_ok(form, "csrf_admin"):
            self.reply(403, page("거부", "<p>CSRF 확인에 실패했습니다.</p>"))
            return
        name = form.get("name", "")
        try:
            with FileLock():
                ensure_layout()
                serial = revoke_name(name)
        except Exception:
            audit("revoke", name, "", "error", self.client_ip(), self.country(), self.admin_cn())
            self.reply(400, page("실패", "<p>폐기하지 못했습니다.</p>"))
            return
        audit("revoke", name, serial, "ok", self.client_ip(), self.country(), self.admin_cn())
        self.reply(200, page("폐기됨", f"<p>{esc(name)} 을 폐기하고 CRL 을 갱신했습니다.</p>"))

    def admin_enroll(self, form):
        if not self.admin_ok():
            return
        if not self.csrf_ok(form, "csrf_admin"):
            self.reply(403, page("거부", "<p>CSRF 확인에 실패했습니다.</p>"))
            return
        name = form.get("name", "")
        if name and not NAME_RE.match(name):
            self.reply(400, page("실패", "<p>이름이 올바르지 않습니다.</p>"))
            return
        raw_minutes = (form.get("minutes") or "").strip()
        if not raw_minutes:
            ttl = default_ttl_seconds()
        else:
            try:
                ttl = clamp_ttl_seconds(int(raw_minutes) * 60)
            except ValueError:
                ttl = default_ttl_seconds()
        with FileLock():
            raw = create_token(name, ttl)
        url = f"{public_base()}/enroll/{raw}"
        audit("enroll_create", name, "", "ok", self.client_ip(), self.country(), self.admin_cn())
        self.reply(200, page("등록 링크", f"<p>한 번만 유효합니다.</p><p><code>{esc(url)}</code></p>"))

    def redirect_enroll(self, token):
        _state, rec = enroll_state(token)
        max_age = default_ttl_seconds()
        if rec and rec.get("expires"):
            max_age = max(1, int(rec["expires"]) - now())
        self.reply(
            302,
            "",
            "text/plain; charset=utf-8",
            extra=[
                ("Location", "/enroll/"),
                ("Set-Cookie", enroll_cookie(token, max_age)),
            ],
        )

    def enroll_page(self, token):
        if not self.proxy_ok():
            return
        ip = self.client_ip()
        if too_many_failures(ip):
            self.reply(429, page("제한", "<p>요청이 너무 많습니다.</p>"))
            return
        state, rec = enroll_state(token)
        if state == "missing":
            note_failure(ip)
            self.reply(404, page("없음", "<p>링크가 없습니다.</p>"))
            return
        if state == "expired":
            self.reply(410, page("만료", "<p>링크가 만료되었습니다.</p>"))
            return
        prefix = "/enroll/ca"
        guide_html = install_block(self.headers.get("User-Agent", ""))
        if state == "used":
            body = (
                "<p>클라이언트 인증서는 이미 발급되었습니다. PKCS#12 는 다시 받을 수 없습니다. "
                "루트 CA 는 이 링크가 만료되기 전까지 받을 수 있습니다.</p>"
                + ca_block(prefix)
                + guide_html
            )
            self.reply(200, page("기기 등록", body))
            return
        csrf = secrets.token_urlsafe(32)
        name = rec.get("name") or ""
        field = (
            f"<input type='hidden' name='name' value='{esc(name)}'>"
            if name
            else "장치 이름 <input name='name'>"
        )
        body = (
            ca_block(prefix)
            + "<form method='post' action='/enroll/'>"
            + f"<input type='hidden' name='csrf' value='{esc(csrf)}'>"
            + f"{field}<button>인증서 만들기</button></form>"
            + guide_html
        )
        self.reply(
            200,
            page("기기 등록", body),
            extra=[("Set-Cookie", f"csrf_enroll={csrf}; HttpOnly; Secure; SameSite=Strict; Path=/enroll")],
        )

    def enroll_submit(self, token, form):
        if not self.proxy_ok():
            return
        ip = self.client_ip()
        if too_many_failures(ip):
            self.reply(429, page("제한", "<p>요청이 너무 많습니다.</p>"))
            return
        if not self.csrf_ok(form, "csrf_enroll"):
            self.reply(403, page("거부", "<p>CSRF 확인에 실패했습니다.</p>"))
            return
        with FileLock():
            rec, data = lookup_token(token)
            if rec is None:
                note_failure(ip)
                self.reply(404, page("없음", "<p>링크가 없습니다.</p>"))
                return
            if rec.get("used") or rec.get("expires", 0) < now():
                self.reply(410, page("만료", "<p>링크가 이미 사용되었거나 만료되었습니다.</p>"))
                return
            rec["used"] = True
            save_tokens(data)
            name = rec.get("name") or form.get("name", "")
            password = secrets.token_urlsafe(12)
            try:
                ensure_layout()
                p12, serial = issue_cert(name, 30, password, False)
            except Exception:
                audit("enroll_use", name, "", "error", ip, self.country(), "-")
                self.reply(400, page("실패", "<p>인증서를 만들지 못했습니다.</p>"))
                return
        item = stash(p12, f"{name}.p12")
        audit("enroll_use", name, serial, "ok", ip, self.country(), "-")
        body = (
            ca_block("/enroll/ca")
            + f"<p>비밀번호: <code>{esc(password)}</code></p>"
            + f"<p><a href='/enroll/dl/{esc(item)}'>PKCS#12 한 번 받기</a></p>"
            + "<p>PKCS#12 는 한 번만 받을 수 있습니다. CA 인증서는 이 링크가 만료되기 전까지 다시 받을 수 있습니다.</p>"
            + install_block(self.headers.get("User-Agent", ""))
        )
        self.reply(200, page("등록됨", body))

    def send_ca(self, der, admin, token=None):
        if admin:
            if not self.admin_ok():
                return
        else:
            if not self.proxy_ok():
                return
            ip = self.client_ip()
            if too_many_failures(ip):
                self.reply(429, page("제한", "<p>요청이 너무 많습니다.</p>"))
                return
            state, _record = enroll_state(token)
            if state == "missing":
                note_failure(ip)
                self.reply(404, page("없음", "<p>링크가 없습니다.</p>"))
                return
            if state == "expired":
                self.reply(410, page("만료", "<p>링크가 만료되었습니다.</p>"))
                return
        pem = load_ca_pem()
        if pem is None:
            self.reply(404, page("없음", "<p>CA 인증서가 없습니다.</p>"))
            return
        if der:
            payload = ca_der(pem)
            content_type = "application/x-x509-ca-cert"
            filename = "webtop-ca.cer"
        else:
            payload = pem
            content_type = "application/x-pem-file"
            filename = "webtop-ca.crt"
        self.reply(
            200,
            payload,
            content_type,
            extra=[("Content-Disposition", f'attachment; filename="{filename}"')],
        )

    def download(self, item_id, admin):
        if admin:
            if not self.admin_ok():
                return
        item = take_stash(item_id)
        if item is None:
            self.reply(410, page("만료", "<p>이미 받았거나 만료된 다운로드입니다.</p>"))
            return
        self.reply(
            200,
            item["bytes"],
            "application/x-pkcs12",
            extra=[("Content-Disposition", f"attachment; filename=\"{item['filename']}\"")],
        )


def serve():
    if not PROXY_SECRET:
        print("CERTADMIN_PROXY_SECRET is required", file=sys.stderr)
        return 1
    ensure_layout()
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()
    return 0


def enroll_cookie(token, max_age):
    max_age = max(1, int(max_age))
    return (
        f"enroll_token={token}; HttpOnly; Secure; SameSite=Strict; "
        f"Path=/enroll; Max-Age={max_age}"
    )


def cli_enroll(name, minutes):
    if name and not NAME_RE.match(name):
        print("bad name", file=sys.stderr)
        return 1
    if minutes is None:
        ttl = default_ttl_seconds()
    else:
        ttl = clamp_ttl_seconds(minutes * 60)
    ensure_layout()
    raw = create_token(name, ttl)
    audit("enroll_create", name, "", "cli", "-", "-", "-")
    print(f"{public_base()}/enroll/{raw}")
    return 0


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("serve", "enroll"))
    parser.add_argument("--name", default="")
    parser.add_argument("--minutes", type=int, default=None)
    args = parser.parse_args(argv)
    if args.command == "serve":
        return serve()
    return cli_enroll(args.name, args.minutes)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
