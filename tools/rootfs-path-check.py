#!/usr/bin/env python3
"""Check one rootfs path without allowing host-relative symlink resolution."""
import argparse
import stat
import sys
from pathlib import Path

from rootfs_paths import RootfsPathError, lstat_rootfs_path, stat_rootfs_path


parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True, type=Path)
parser.add_argument("--path", required=True)
parser.add_argument(
    "--kind",
    choices=("any", "regular", "executable", "regular-or-symlink"),
    default="any",
)
parser.add_argument("--no-follow-final", action="store_true")
parser.add_argument("--print-host-path", action="store_true")
args = parser.parse_args()

try:
    finder = lstat_rootfs_path if args.no_follow_final else stat_rootfs_path
    entry = finder(args.root, args.path)
except RootfsPathError as error:
    print(error, file=sys.stderr)
    raise SystemExit(2) from error

if entry is None:
    raise SystemExit(1)

mode = entry.stat.st_mode
matches = {
    "any": True,
    "regular": stat.S_ISREG(mode),
    "executable": stat.S_ISREG(mode) and bool(mode & 0o111),
    "regular-or-symlink": stat.S_ISREG(mode) or stat.S_ISLNK(mode),
}[args.kind]
if not matches:
    raise SystemExit(1)
if args.print_host_path:
    print(entry.path)
