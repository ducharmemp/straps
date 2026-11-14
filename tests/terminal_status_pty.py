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
    states = [message.split(b':state=')[1] for message in messages]
    check(states == [b'working', b'blocked:kind=permission', b'working', b'done', b'clear'], states)
    ids = [message.split(b':id=')[1].split(b':state=')[0] for message in messages]
    check(len(set(ids)) == 1 and ids[0].startswith(b'straps/'), ids)
    check(all(message.startswith(b'app=straps:id=') for message in messages), messages)
    print('Actual terminal OSC 7501 output passed: lifecycle, blocked state, task identity, shutdown clear')
