#!/usr/bin/env python3
"""Restore every parent entry except the three deliberately child-owned mutable records."""
import argparse
import os
import shutil
import stat
from pathlib import Path
from rootfs_paths import (
    RootfsPathError,
    destination_rootfs_path,
    lstat_rootfs_path,
    walk_rootfs,
)


parser = argparse.ArgumentParser()
parser.add_argument("--parent", required=True, type=Path)
parser.add_argument("--rootfs", required=True, type=Path)
args = parser.parse_args()

excluded = ("var/lib/rpm", "etc/ld.so.cache", "etc/nwarila/fips-status.json")
hardlinks = {}

def excluded_path(relative):
    text = str(relative)
    return any(text == item or text.startswith(item + "/") for item in excluded)

def target_state(relative):
    try:
        entry = lstat_rootfs_path(args.rootfs, relative)
        destination, _ = destination_rootfs_path(args.rootfs, relative)
    except RootfsPathError as error:
        raise SystemExit(str(error)) from error
    return entry, destination

def remove_entry(entry):
    if stat.S_ISDIR(entry.stat.st_mode):
        shutil.rmtree(entry.path)
    else:
        entry.path.unlink()

sources = sorted(walk_rootfs(args.parent),
                 key=lambda entry: (len(entry.relative.parts), str(entry.relative).encode()))
for source_entry in sources:
    source = source_entry.path
    relative = source_entry.relative
    if excluded_path(relative):
        continue
    entry, target = target_state(relative)
    info = source_entry.stat
    if stat.S_ISDIR(info.st_mode):
        if entry is not None and not stat.S_ISDIR(entry.stat.st_mode):
            remove_entry(entry)
        target.mkdir(parents=True, exist_ok=True)
        os.chown(target, info.st_uid, info.st_gid)
        os.chmod(target, stat.S_IMODE(info.st_mode))
    elif stat.S_ISLNK(info.st_mode):
        target.parent.mkdir(parents=True, exist_ok=True)
        if entry is not None:
            remove_entry(entry)
        target.symlink_to(os.readlink(source))
        os.lchown(target, info.st_uid, info.st_gid)
    elif stat.S_ISREG(info.st_mode):
        target.parent.mkdir(parents=True, exist_ok=True)
        identity = (info.st_dev, info.st_ino)
        if info.st_nlink > 1 and identity in hardlinks:
            if entry is not None:
                remove_entry(entry)
            os.link(hardlinks[identity], target)
        else:
            if entry is not None:
                remove_entry(entry)
            shutil.copy2(source, target, follow_symlinks=False)
            hardlinks[identity] = target
        os.chown(target, info.st_uid, info.st_gid)
        os.chmod(target, stat.S_IMODE(info.st_mode))
