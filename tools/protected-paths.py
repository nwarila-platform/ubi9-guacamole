#!/usr/bin/env python3
"""Compute protected providers from shipped ELF roots, excluding support-owned roots."""
import argparse
import json
import os
import stat
import subprocess
import sys
from collections import deque
from pathlib import Path, PurePosixPath
from elf_contract import ElfError, inspect_elf
from rootfs_paths import RootfsPathError, resolve_rootfs_path, rootfs_root, walk_rootfs


parser = argparse.ArgumentParser()
parser.add_argument("--rootfs", required=True, type=Path)
parser.add_argument("--support-package", action="append", required=True)
parser.add_argument("--required-elf", action="append", default=[])
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
root = rootfs_root(args.rootfs)

package_query_failures = []


def installed_paths(package):
    query = subprocess.run(
        ["rpm", f"--root={root}", "-ql", package],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if query.returncode != 0:
        package_query_failures.append(f"{package}: status={query.returncode}")
        return []
    return [line for line in query.stdout.splitlines() if line.startswith("/")]

def real_inside(path_text):
    try:
        resolved = resolve_rootfs_path(root, path_text)
    except RootfsPathError as error:
        raise SystemExit(str(error)) from error
    return "/" + str(resolved) if resolved is not None else None

support_owned = set()
resolution_failures = []
for package in args.support_package:
    for path in installed_paths(package):
        try:
            resolved = real_inside(path)
        except SystemExit as error:
            resolution_failures.append(f"{package}:{path}:{error}")
            continue
        if resolved:
            support_owned.add(resolved)

elfs = []
parse_failures = []
for entry in walk_rootfs(root):
    if stat.S_ISREG(entry.stat.st_mode):
        try:
            if entry.path.open("rb").read(4) == b"\x7fELF":
                elfs.append((entry.path, entry.relative))
        except OSError as error:
            parse_failures.append(f"/{entry.relative}:{error}")

metadata = {}
providers = {}
for path, relative_path in elfs:
    try:
        elf = inspect_elf(path)
    except (ElfError, OSError, UnicodeError) as error:
        parse_failures.append(f"/{relative_path}:{error}")
        continue
    relative = "/" + str(relative_path)
    needed = elf["needed"]
    sonames = elf["sonames"]
    metadata[relative] = needed
    providers.setdefault(path.name, []).append(relative)
    for soname in sonames:
        providers.setdefault(soname, []).append(relative)

required_roots = set()
required_root_failures = []
for required in args.required_elf:
    canonical = None
    if required.startswith("/") and required != "/":
        try:
            canonical = "/" + str(PurePosixPath(required).relative_to("/"))
        except ValueError:
            pass
    if canonical != required or ".." in PurePosixPath(required or "/").parts:
        required_root_failures.append(f"{required}: invalid-absolute-path")
    elif required in required_roots:
        required_root_failures.append(f"{required}: duplicate")
    elif required not in metadata:
        required_root_failures.append(f"{required}: missing-or-not-ELF")
    else:
        required_roots.add(required)

def resolve(soname):
    matches = sorted(set(providers.get(soname, [])), key=lambda item: (
        0 if item.startswith("/usr/lib64/") else 1,
        0 if item.startswith("/lib64/") else 1,
        item.encode(),
    ))
    return matches[0] if matches else None

roots = sorted((path for path in metadata if path not in support_owned), key=lambda item: item.encode())
protected = set(required_roots)
queue = deque(roots)
seen = set(roots)
missing = []
while queue:
    current = queue.popleft()
    for soname in metadata.get(current, []):
        provider = resolve(soname)
        if not provider:
            missing.append({"root": current, "soname": soname})
            continue
        protected.add(provider)
        if provider not in seen:
            seen.add(provider)
            queue.append(provider)

conflict = sorted(protected & support_owned, key=lambda item: item.encode())
missing_rows = sorted(
    {f"{item['root']}:{item['soname']}" for item in missing}, key=os.fsencode
)
groups = (
    ("support-owned paths required by shipped ELF", conflict),
    ("unresolved shipped ELF dependencies", missing_rows),
    ("support path resolution failures", resolution_failures),
    ("support package query failures", package_query_failures),
    ("ELF parse failures", parse_failures),
    ("required ELF root failures", required_root_failures),
)
failure_count = sum(len(values) for _, values in groups)
if failure_count:
    for label, values in groups:
        ordered = sorted(values, key=os.fsencode)
        print(f"{label} count={len(ordered)}", file=sys.stderr)
        for value in ordered:
            print(value, file=sys.stderr)
    raise SystemExit(f"protected-path inventory failures count={failure_count}")

document = {
    "version": 1,
    "algorithm": "shipped-elf-roots-excluding-support-owned+declared-dynamic-roots/transitive-DT_NEEDED",
    "required_elf_roots": sorted(required_roots, key=lambda item: item.encode()),
    "support_owned": sorted(support_owned, key=lambda item: item.encode()),
    "shipped_elf_roots": roots,
    "protected": sorted(protected, key=lambda item: item.encode()),
    "unresolved": missing,
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"protected roots={len(roots)} providers={len(protected)} support={len(support_owned)}")
