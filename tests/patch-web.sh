#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/index.html" <<'EOF'
<html>
  <body>
    <script src="public/js/kclient.js"></script>
  </body>
</html>
EOF
cat > "$tmp/vnc.html" <<'EOF'
<html>
  <body>
    <div id="screen"></div>
  </body>
</html>
EOF

python3 "$ROOT/kasm/patch-web.py" "$tmp/index.html" parent
python3 "$ROOT/kasm/patch-web.py" "$tmp/vnc.html" frame
grep -q 'public/js/webtop-audio.js' "$tmp/index.html"
grep -q 'src="webtop-audio.js"' "$tmp/vnc.html"
printf '%s' '<html><div id="screen"></div>' > "$tmp/min.html"
python3 "$ROOT/kasm/patch-web.py" "$tmp/min.html" frame
grep -q 'src="webtop-audio.js"' "$tmp/min.html"
# Idempotent.
python3 "$ROOT/kasm/patch-web.py" "$tmp/index.html" parent | grep -q 'already patched'
python3 "$ROOT/kasm/patch-web.py" "$tmp/vnc.html" frame | grep -q 'already patched'
echo "patch-web ok"
