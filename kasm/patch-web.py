#!/usr/bin/env python3
"""Insert the webtop audio hook into a Kasm web page.

parent: the kclient shell, after kclient.js (audio() must already exist).
frame: the VNC page, so a gesture on the desktop reaches the parent.
"""

import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: patch-web.py FILE parent|frame")
    path = Path(sys.argv[1])
    kind = sys.argv[2]
    if not path.is_file():
        sys.exit(f"missing {path}")
    text = path.read_text()
    if "webtop-audio.js" in text:
        print(f"already patched {path}")
        return
    if kind == "parent":
        needle = '<script src="public/js/kclient.js"></script>'
        insert = needle + '\n    <script src="public/js/webtop-audio.js"></script>'
        if needle not in text:
            sys.exit(f"kclient.js script tag not found in {path}")
        text = text.replace(needle, insert, 1)
    elif kind == "frame":
        # The packaged noVNC page is minified and has no </body>.
        snippet = '<script src="webtop-audio.js"></script>\n'
        if "</body>" in text:
            text = text.replace("</body>", snippet + "</body>", 1)
        else:
            if not text.endswith("\n"):
                text += "\n"
            text += snippet
    else:
        sys.exit("kind must be parent or frame")
    path.write_text(text)
    print(f"patched {path}")


if __name__ == "__main__":
    main()
