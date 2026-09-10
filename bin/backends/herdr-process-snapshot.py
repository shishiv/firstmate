#!/usr/bin/env python3
"""Read one pane's process tree; never signal processes or trust a status label.

stdin: Herdr pane.process_info result. stdout: a bounded process snapshot and
whether two kernel observations prove only an interactive shell/wrapper chain.
The caller owns harness-name classification; unknown processes never prove death.
"""
import json
import os
import shlex
import subprocess
import sys
import time


def process(pid, deadline=None):
    def remaining():
        budget = 2 if deadline is None else deadline - time.monotonic()
        if budget <= 0:
            raise ValueError("process observation deadline")
        return budget
    remaining()
    if sys.platform.startswith("linux"):
        with open(f"/proc/{pid}/stat", encoding="utf8") as handle:
            raw = handle.read()
        tail = raw[raw.rindex(")") + 2:].split()
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            argv = [arg.decode("utf8", "strict") for arg in handle.read().split(b"\0") if arg]
        return dict(pid=pid, ppid=int(tail[1]), pgid=int(tail[2]),
                    identity=tail[19], comm=raw[raw.index("(") + 1:raw.rindex(")")],
                    argv=argv, state=tail[0])
    row = subprocess.check_output(
        ["ps", "-p", str(pid), "-o", "ppid=,pgid=,stat=,lstart=,comm="],
        text=True, timeout=remaining()).strip().split(None, 8)
    if len(row) != 9:
        raise ValueError("incomplete process identity")
    args = subprocess.check_output(["ps", "-p", str(pid), "-o", "args="], text=True, timeout=remaining())
    return dict(pid=pid, ppid=int(row[0]), pgid=int(row[1]), state=row[2],
                identity=" ".join(row[3:8]), comm=row[8], argv=shlex.split(args))


def snapshot(root):
    deadline = time.monotonic() + 2
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True, timeout=2)
    parents = {int(pid): int(parent) for pid, parent in (row.split() for row in rows.splitlines())}
    selected = {root}
    while True:
        found = {pid for pid, parent in parents.items() if parent in selected}
        if found <= selected:
            break
        selected |= found
        if len(selected) > 128:
            raise ValueError("pane tree exceeds observation bound")
    return [process(pid, deadline) for pid in sorted(selected)]


def shell_chain(rows, root, foreground):
    """Negative proof only: no jobs, scripts, unknown children or hidden branches."""
    shells = {"bash", "zsh", "sh", "dash", "ash", "ksh", "mksh", "tcsh", "csh", "fish"}
    by_pid = {row["pid"]: row for row in rows}
    seen = set()
    pid = root
    while pid in by_pid and pid not in seen:
        seen.add(pid)
        row = by_pid[pid]
        argv = row["argv"]
        name = os.path.basename(row["comm"]).lstrip("-")
        children = [child["pid"] for child in rows if child["ppid"] == pid]
        if not argv or row["state"].startswith(("Z", "T")):
            return False
        if name in shells:
            if os.path.basename(argv[0]).lstrip("-") not in shells:
                return False
            if any(arg not in {"-i", "-l", "--login", "--noprofile", "--norc"} for arg in argv[1:]):
                return False
        elif name == "treehouse":
            if os.path.basename(argv[0]) != "treehouse" or len(children) != 1:
                return False
        else:
            return False
        if not children:
            return name in shells and row["pgid"] == foreground and len(seen) == len(rows)
        if len(children) != 1:
            return False
        pid = children[0]
    return False


def observe(info):
    root = info["shell_pid"]
    foreground = info["foreground_process_group_id"]
    if type(root) is not int or type(foreground) is not int or min(root, foreground) <= 1:
        raise ValueError("invalid process binding")
    before = snapshot(root)
    by_pid = {row["pid"]: row for row in before}
    expected = info["foreground_processes"]
    if not expected or not all(row["pid"] in by_pid and by_pid[row["pid"]]["pgid"] == foreground for row in expected):
        raise ValueError("foreground is not bound to pane shell")
    after = snapshot(root)
    return {"processes": before, "shell_only": before == after and shell_chain(after, root, foreground)}


if __name__ == "__main__":
    try:
        print(json.dumps(observe(json.load(sys.stdin)["result"]["process_info"])))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print('{"error":"unreadable"}')
