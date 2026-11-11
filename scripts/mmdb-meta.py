#!/usr/bin/env python3
"""Print MaxMind DB metadata from a file path or stdin. No third-party packages."""

import sys
from datetime import datetime, timezone


def decode(buf, off):
    ctrl = buf[off]
    off += 1
    typ = ctrl >> 5
    size = ctrl & 0x1F
    if typ == 0:
        typ = buf[off] + 7
        off += 1
    if size >= 29:
        extra = size - 28
        size = 29
        for _ in range(extra):
            size = (size << 8) + buf[off]
            off += 1
        if extra == 1:
            size += 29
        elif extra == 2:
            size += 285
        else:
            size += 65821
    if typ == 1:
        # Pointers do not appear in the metadata section we read.
        raise ValueError("unexpected pointer in metadata")
    if typ == 2:
        end = off + size
        return buf[off:end].decode("utf-8", "replace"), end
    if typ in (5, 6, 9, 10):
        width = {5: 2, 6: 4, 9: 8, 10: 16}[typ]
        raw = buf[off : off + size]
        off += size
        if len(raw) < width:
            raw = (b"\x00" * (width - len(raw))) + raw
        return int.from_bytes(raw, "big"), off
    if typ == 7:
        out = {}
        for _ in range(size):
            key, off = decode(buf, off)
            val, off = decode(buf, off)
            out[key] = val
        return out, off
    if typ == 8:
        raw = buf[off : off + size]
        off += size
        if len(raw) < 4:
            raw = (b"\x00" * (4 - len(raw))) + raw
        return int.from_bytes(raw, "big", signed=True), off
    if typ == 11:
        out = []
        for _ in range(size):
            val, off = decode(buf, off)
            out.append(val)
        return out, off
    if typ == 14:
        return size != 0, off
    if typ == 3:
        off += 8
        return None, off
    if typ == 15:
        off += 4
        return None, off
    if typ == 4:
        end = off + size
        return buf[off:end], end
    raise ValueError(f"unsupported metadata type {typ}")


def metadata(blob):
    marker = b"\xab\xcd\xefMaxMind.com"
    at = blob.rfind(marker)
    if at < 0:
        raise ValueError("not a MaxMind DB")
    meta, _off = decode(blob, at + len(marker))
    if not isinstance(meta, dict):
        raise ValueError("metadata is not a map")
    return meta


def main(argv):
    if len(argv) > 1 and argv[1] != "-":
        blob = open(argv[1], "rb").read()
    else:
        blob = sys.stdin.buffer.read()
    meta = metadata(blob)
    epoch = int(meta.get("build_epoch") or 0)
    when = datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC") if epoch else "-"
    kind = meta.get("database_type") or "-"
    desc = meta.get("description") or {}
    if isinstance(desc, dict):
        desc = desc.get("en") or next(iter(desc.values()), "-")
    print(f"database_type={kind}")
    print(f"description={desc}")
    print(f"build_epoch={epoch}")
    print(f"build_time={when}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:
        print(f"mmdb-meta: {exc}", file=sys.stderr)
        sys.exit(1)
