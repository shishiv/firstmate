#!/usr/bin/env bash
# Kernel-backed pane liveness without Herdr or an actual model process.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 -c 'import fcntl, pty, termios' 2>/dev/null || {
  echo 'skip: kernel pane proof needs Unix PTY support'
  exit 0
}
python3 - "$ROOT" <<'PY'
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
import termios

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('probe', root / 'bin/backends/herdr-process-snapshot.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def row(pid, parent, name, args=None, group=30):
    return dict(pid=pid, ppid=parent, pgid=group, comm=name,
                argv=args or [name], identity=str(pid), state='S')

chain = [row(10, 1, 'bash'), row(20, 10, 'treehouse', ['treehouse', 'get', 'repo']), row(30, 20, 'bash')]
assert probe.shell_chain(chain, 10, 30)
for extra in [row(40, 10, 'sleep'), row(40, 30, 'bash', ['bash', '-c', 'work'])]:
    assert not probe.shell_chain(chain + [extra], 10, 30)
changed = copy.deepcopy(chain)
changed[0]['identity'] = 'recycled'
real_snapshot = probe.snapshot
snapshots = iter([chain, changed])
probe.snapshot = lambda _: next(snapshots)
assert not probe.observe(dict(shell_pid=10, foreground_process_group_id=30,
                              foreground_processes=[dict(pid=30)]))['shell_only']
probe.snapshot = real_snapshot
print('ok - nested Treehouse shells are distinct from scripts, unknown children and recycled process identities')

command = r'''
. "$1/bin/backends/herdr.sh"
fm_backend_herdr_cli() {
  case "$2 $3" in
    'pane get') printf '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
    'pane process-info') cat "$FM_TEST_PROCESS_INFO" ;;
    'agent get') printf '{"result":{"agent":{"agent_status":"idle"}}}' ;;
    *) return 97 ;;
  esac
}
fm_backend_herdr_agent_state fixture:w1:p2
'''

def run_case(script, expected):
    master, slave = pty.openpty()
    def setup():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    env = dict(os.environ, PS1='PROBE_READY> ')
    child = subprocess.Popen(['bash', '--noprofile', '--norc', '-i'], stdin=slave,
                             stdout=slave, stderr=slave, env=env, preexec_fn=setup)
    os.close(slave)
    try:
        for _ in range(100):
            if select.select([master], [], [], .03)[0] and b'PROBE_READY>' in os.read(master, 8192):
                break
        else:
            raise AssertionError('owned shell did not start')
        os.write(master, script.encode() + b'\n')
        for _ in range(100):
            rows = probe.snapshot(child.pid)
            if expected == 'dead' and len(rows) == 2:
                break
            if expected != 'dead' and rows[0]['comm'] == 'sleep':
                break
            time.sleep(.02)
        else:
            raise AssertionError('owned fixture did not reach intended process topology')
        fg = os.tcgetpgrp(master)
        info = dict(result=dict(process_info=dict(pane_id='w1:p2', shell_pid=child.pid,
            foreground_process_group_id=fg,
            foreground_processes=[dict(pid=r['pid']) for r in rows if r['pgid'] == fg])))
        if expected == 'alive':
            assert rows[0]['comm'] == 'sleep' and rows[0]['argv'][0] == 'pi', 'signals must diverge'
        with tempfile.TemporaryDirectory(prefix='fm-process-proof-') as directory:
            path = Path(directory) / 'info.json'
            path.write_text(json.dumps(info))
            verdict = subprocess.check_output(['bash', '-c', command, 'fixture', str(root)],
                env=dict(env, FM_TEST_PROCESS_INFO=str(path), FM_HOME=directory), text=True, timeout=8)
            assert verdict == expected, (expected, verdict)
            info['result']['process_info']['pane_id'] = 'wrong:pane'
            path.write_text(json.dumps(info))
            verdict = subprocess.check_output(['bash', '-c', command, 'fixture', str(root)],
                env=dict(env, FM_TEST_PROCESS_INFO=str(path), FM_HOME=directory), text=True, timeout=8)
            assert verdict == 'unreadable', verdict
    finally:
        os.close(master)
        if child.poll() is None:
            child.send_signal(signal.SIGHUP)
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    print('ok - real pane processes:', expected, '; mismatched pane identity refuses')

run_case('bash --noprofile --norc -i', 'dead')
run_case('exec -a pi sleep 60', 'alive')
run_case('exec sleep 60', 'ambiguous')
PY
