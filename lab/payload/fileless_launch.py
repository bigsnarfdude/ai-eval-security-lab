#!/usr/bin/env python3
"""
Fileless exec via memfd_create — run a binary OR a script entirely from RAM, with no on-disk
path backing the running image. This is the technique real fileless malware uses to dodge
file/disk scanning; here it's how we generate a controlled sample to hunt in memory.

Usage:
    fileless_launch.py <file> [args...]

  - ELF binary  -> execve the memfd directly; /proc/<pid>/exe becomes 'memfd:<name> (deleted)'
  - #! script    -> interpreter runs the script from /proc/self/fd/<memfd>; the script content
                    lives only in the (deleted) memfd, visible as /proc/<pid>/fd/<N>
"""
import os, sys

def main():
    if len(sys.argv) < 2:
        sys.exit("usage: fileless_launch.py <file> [args...]")
    target, args = sys.argv[1], sys.argv[2:]
    data = open(target, "rb").read()
    name = os.path.basename(target)

    # flags=0 -> NOT close-on-exec, so the fd survives execv and the interpreter can read the
    # script from /proc/self/fd/<N>. (Python defaults memfd_create to MFD_CLOEXEC, which breaks this.)
    fd = os.memfd_create(name, 0)       # anonymous, RAM-backed, inheritable across execv
    os.write(fd, data)
    fdpath = f"/proc/self/fd/{fd}"

    first_line = data.split(b"\n", 1)[0]
    if data[:2] == b"#!" and b"python" in first_line:
        # script mode: the new python inherits the memfd and reads the script from it
        os.execv(sys.executable, [name, fdpath, *args])
    else:
        # binary mode: kernel executes the memfd image; exe backing shows as deleted
        os.execv(fdpath, [name, *args])

if __name__ == "__main__":
    main()
