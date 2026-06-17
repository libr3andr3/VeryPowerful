#!/usr/bin/env python3
"""LibreSynergy Usage Aggregator — runs via cron every 5 minutes.
Reads nginx stream access log, accumulates byte counts per domain
to flat-file counters. Zero dependencies (stdlib only).

Flat-file format (/var/lib/libresynergy/usage/<domain>):
  <total_bytes_out> <total_bytes_in> <total_connections> <last_updated_iso>
"""
import os
import sys
import time
import signal
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

USAGE_DIR = Path("/var/lib/libresynergy/usage")
LOG_PATH = Path("/var/log/nginx/stream-access.log")
STATE_FILE = USAGE_DIR / ".aggregator_state"
LOCK_FILE = USAGE_DIR / ".aggregator.lock"


def acquire_lock() -> bool:
    """Simple PID-based lock to prevent concurrent runs."""
    try:
        if LOCK_FILE.exists():
            pid = int(LOCK_FILE.read_text().strip())
            try:
                os.kill(pid, 0)
                return False  # still running
            except OSError:
                pass  # stale lock
        LOCK_FILE.write_text(str(os.getpid()))
        return True
    except Exception:
        return False


def release_lock():
    try:
        LOCK_FILE.unlink(missing_ok=True)
    except Exception:
        pass


def read_log_since(position: int) -> tuple[dict[str, tuple[int, int, int]], int]:
    """Parse access log from given byte position.
    Returns (domain -> (bytes_out, bytes_in, conns), new_position).
    """
    counts: dict[str, tuple[int, int, int]] = defaultdict(lambda: (0, 0, 0))

    try:
        with open(LOG_PATH, "r") as f:
            if position > 0:
                f.seek(position)
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split()
                if len(parts) < 4:
                    continue
                domain = parts[0]
                try:
                    bytes_sent = int(parts[1])
                    bytes_recv = int(parts[2])
                except (ValueError, IndexError):
                    continue

                prev = counts[domain]
                counts[domain] = (prev[0] + bytes_sent, prev[1] + bytes_recv, prev[2] + 1)
            new_pos = f.tell()
    except FileNotFoundError:
        return counts, 0

    return counts, new_pos


def update_counters(counts: dict[str, tuple[int, int, int]]):
    """Add new counts to flat-file counters. Atomic write via temp file."""
    now = datetime.now(timezone.utc).isoformat()

    for domain, (b_out, b_in, conns) in counts.items():
        fpath = USAGE_DIR / domain
        old_out, old_in, old_conns = 0, 0, 0

        if fpath.exists():
            try:
                data = fpath.read_text().split()
                old_out = int(data[0])
                old_in = int(data[1])
                old_conns = int(data[2]) if len(data) > 2 else 0
            except (ValueError, IndexError):
                pass

        new_out = old_out + b_out
        new_in = old_in + b_in
        new_conns = old_conns + conns

        # Atomic write
        tmp = fpath.with_suffix(".tmp")
        tmp.write_text(f"{new_out} {new_in} {new_conns} {now}\n")
        tmp.rename(fpath)


def main():
    if not acquire_lock():
        print("aggregator already running", file=sys.stderr)
        sys.exit(0)

    try:
        USAGE_DIR.mkdir(parents=True, exist_ok=True)

        # Read last position
        last_pos = 0
        if STATE_FILE.exists():
            try:
                last_pos = int(STATE_FILE.read_text().strip())
            except ValueError:
                pass

        # Parse new log entries
        counts, new_pos = read_log_since(last_pos)

        if counts:
            update_counters(counts)

        # Save position — only advance if we actually read something,
        # so a partial line at the end gets re-read next time
        if new_pos > last_pos:
            STATE_FILE.write_text(str(new_pos))

        # Summary
        total_conns = sum(c[2] for c in counts.values())
        total_bytes = sum(c[0] + c[1] for c in counts.values())
        if total_conns > 0:
            print(f"aggregated {total_conns} connections, "
                  f"{total_bytes / 1024:.1f} KB across {len(counts)} domains")

    finally:
        release_lock()


if __name__ == "__main__":
    main()
