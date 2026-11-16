"""Runs a command on a 100x30 pseudo-terminal until a file exists or the time runs out, then sends Ctrl+C.

Usage: python3 -I pty.py <seconds> <file> <cmd...>

Exits 0 when the file appeared, 1 when it did not; prints how many bytes the command drew.
"""

import os
import pty
import select
import signal
import struct
import sys
import time
import fcntl
import termios

seconds, marker = float(sys.argv[1]), sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[3], sys.argv[3:])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
drawn = 0
end = time.time() + seconds
while time.time() < end and not os.path.exists(marker):
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        drawn += len(chunk)
found = os.path.exists(marker)
# Ctrl+C twice (the first may clear the prompt), then a kill if it outlives three seconds.
for _ in range(2):
    try:
        os.write(fd, b"\x03")
    except OSError:
        break
    time.sleep(0.3)
deadline = time.time() + 3
while time.time() < deadline:
    if os.waitpid(pid, os.WNOHANG)[0] == pid:
        break
    try:
        select.select([fd], [], [], 0.1) and os.read(fd, 65536)
    except OSError:
        pass
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
print(f"TUI: {drawn} bytes drawn, marker {'found' if found else 'missing'}")
sys.exit(0 if found else 1)
