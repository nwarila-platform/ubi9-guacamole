#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys
from pathlib import Path
from rootfs_paths import RootfsPathError, lstat_rootfs_path, rootfs_root

parser = argparse.ArgumentParser()
parser.add_argument("--parent", required=True, type=Path)
parser.add_argument("--rpm", action="append", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
parent = rootfs_root(args.parent)

payload = set()
rpm_query_failures = []
for rpm in args.rpm:
    query = subprocess.run(
        ["rpm", "-qpl", str(rpm)], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if query.returncode != 0:
        rpm_query_failures.append(f"{rpm}: status={query.returncode}")
        continue
    payload.update(line.lstrip("/") for line in query.stdout.splitlines() if line.startswith("/"))
paths = []
resolution_failures = []
for relative in sorted(payload, key=lambda item: item.encode()):
    try:
        entry = lstat_rootfs_path(parent, "/" + relative)
    except RootfsPathError as error:
        resolution_failures.append(f"/{relative}: {error}")
        continue
    if entry is not None:
        paths.append(relative)
failures = (
    ("parent-overlap RPM query failures", rpm_query_failures),
    ("parent-overlap resolution failures", resolution_failures),
)
if any(values for _, values in failures):
    for label, values in failures:
        values.sort(key=os.fsencode)
        print(f"{label} count={len(values)}", file=sys.stderr)
        for failure in values:
            print(failure, file=sys.stderr)
    raise SystemExit(1)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text("".join(path + "\n" for path in paths), encoding="utf-8")
print(f"parent-overlap={len(paths)}")
