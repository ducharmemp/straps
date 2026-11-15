import errno
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import tempfile
import time

assertion_count = 0


def check(value, detail):
    global assertion_count
    assertion_count += 1
    if os.environ.get('STRAPS_STATUS_COUNTERFACTUAL') == str(assertion_count):
        value = not value
    assert value, f'terminal assertion {assertion_count}: {detail}'


root = Path(__file__).resolve().parents[1]
source = r'''
vim.opt.rtp:prepend(ROOT)
package.path = ROOT .. '/lua/?.lua;' .. ROOT .. '/lua/?/init.lua;' .. package.path
local a = require('straps.attention')
a.setup(true)
local b = vim.api.nvim_create_buf(false, true)
local r = { ctx = { bufnr = b } }
a.start(b, r)
local release = a.wait(r.ctx, 'permission')
release()
a.finish(b, r, 'ok')
a.shutdown()
vim.defer_fn(function() vim.cmd('qa!') end, 100)
'''.replace('ROOT', repr(str(root)))
with tempfile.TemporaryDirectory() as directory:
    script = Path(directory) / 'status.lua'
    script.write_text(source)
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    process = subprocess.Popen(['nvim', '--clean', '-n', '-i', 'NONE', '-c', f'luafile {script}'],
                               stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    output = bytearray()
    deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.1)
            if readable:
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                output.extend(data)
            elif process.poll() is not None:
                break
        if process.poll() is None:
            process.kill()
            raise AssertionError('terminal Neovim did not exit within 15 seconds')
        check(process.wait() == 0, bytes(output))
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
    messages = re.findall(rb'\x1b\]7501;([^\x1b]*)\x1b\\', output)
    reports = []
    for message in messages:
        match = re.fullmatch(rb'app=straps(?::id=([^:]+))?:state=([^:]+)(?::kind=([a-z]+))?', message)
        check(match is not None, message)
        reports.append(match.groups())
    ids = {report[0] for report in reports if report[0] is not None}
    check(len(ids) == 1, ids)
    task_id = next(iter(ids))
    check(task_id.startswith(b'straps/'), task_id)
    check(reports == [
        (task_id, b'working', None), (None, b'working', None),
        (task_id, b'blocked', b'permission'), (None, b'blocked', b'permission'),
        (task_id, b'working', None), (None, b'working', None),
        (task_id, b'clear', None), (None, b'done', None), (None, b'clear', None),
    ], reports)
    tasks = {}
    root_state = None
    expected = [None, b'working', b'blocked', b'blocked', b'blocked', b'working', b'working', b'done', None]
    for (identity, state, kind), effective in zip(reports, expected):
        if state == b'clear':
            if identity is None:
                tasks.clear()
                root_state = None
            else:
                tasks.pop(identity, None)
        elif identity is None:
            root_state = state
        else:
            tasks[identity] = state
        consumer_state = root_state
        for task_state in tasks.values():
            if task_state == b'blocked' or (task_state == b'error' and consumer_state != b'blocked'):
                consumer_state = task_state
        check(consumer_state == effective, (consumer_state, effective))
    check(tasks == {}, tasks)
    check(root_state is None, root_state)
    print(f'Actual terminal OSC 7501 output passed; terminal status assertions: {assertion_count}')
