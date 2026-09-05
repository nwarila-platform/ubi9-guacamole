#!/usr/bin/env python3
"""Remove unloadable ELF payload that is outside the declared RDP runtime closure."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
from collections import defaultdict, deque
from pathlib import Path, PurePosixPath

from elf_contract import ElfError, inspect_elf
from rootfs_paths import RootfsPathError, rootfs_root, stat_rootfs_path, walk_rootfs


class AuditError(RuntimeError):
    """The rootfs could not be classified safely."""


def byte_sorted(values):
    return sorted(values, key=os.fsencode)


def report(label, values):
    ordered = byte_sorted(values)
    print(f"{label} count={len(ordered)}", file=sys.stderr)
    for value in ordered:
        print(value, file=sys.stderr)


def rpm_query(root, *arguments):
    result = subprocess.run(
        ["rpm", f"--root={root}", *arguments],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip().splitlines()
        suffix = f": {detail[0]}" if detail else ""
        raise AuditError(f"RPM query failed ({' '.join(arguments)}){suffix}")
    return result.stdout


def elf_inventory(root):
    inventory = {}
    failures = []
    for entry in walk_rootfs(root):
        if not stat.S_ISREG(entry.stat.st_mode):
            continue
        display = "/" + str(entry.relative)
        try:
            if entry.path.open("rb").read(4) != b"\x7fELF":
                continue
            contract = inspect_elf(entry.path)
        except (OSError, ElfError) as error:
            failures.append(f"{display}: {error}")
            continue
        inventory[display] = {
            "entry": entry,
            "needed": tuple(contract["needed"]),
            "sonames": tuple(contract["sonames"]),
        }
    if failures:
        report("ELF prune inventory failures", failures)
        raise AuditError("ELF inventory is not inspectable")
    return inventory


def requirement_owners(root):
    rendered = rpm_query(root, "-qa", "--qf", "%{NAME}\t%{NEVRA}\n")
    packages = {}
    malformed = []
    for line in rendered.splitlines():
        if "\t" not in line:
            malformed.append(line)
            continue
        name, nevra = line.split("\t", 1)
        if not name or not nevra or name in packages:
            malformed.append(line)
            continue
        packages[name] = nevra
    if malformed:
        report("ELF prune malformed RPM package inventory", malformed)
        raise AuditError("RPM package inventory is malformed or contains duplicate names")

    owners = defaultdict(set)
    for name in byte_sorted(packages):
        requirements = rpm_query(root, "-q", name, "--qf", "[%{REQUIRENAME}\n]")
        for requirement in requirements.splitlines():
            if not requirement:
                raise AuditError(f"empty RPM requirement rendered for {packages[name]}")
            owners[requirement].add(packages[name])
    return owners


def application_seeds(root, inventory, package):
    package_paths = rpm_query(root, "-q", package, "--qf", "[%{FILENAMES}\n]")
    seeds = set()
    resolution_failures = []
    for package_path in package_paths.splitlines():
        if not package_path.startswith("/"):
            resolution_failures.append(f"{package}: invalid-path={package_path}")
            continue
        try:
            entry = stat_rootfs_path(root, package_path)
        except RootfsPathError as error:
            resolution_failures.append(f"{package_path}: {error}")
            continue
        if entry is None or not stat.S_ISREG(entry.stat.st_mode):
            continue
        display = "/" + str(entry.relative)
        if display in inventory:
            seeds.add(display)
    if resolution_failures:
        report("ELF prune application path failures", resolution_failures)
        raise AuditError("application package paths are not safely resolvable")
    if "/usr/sbin/guacd" not in seeds:
        raise AuditError("guacamole-server does not seed /usr/sbin/guacd")
    if not any(Path(path).name.startswith("libguac-client-rdp.so") for path in seeds):
        raise AuditError("guacamole-server does not seed its declared RDP client plugin")
    return seeds


def required_elf_seeds(inventory, required_paths):
    seeds = set()
    failures = []
    seen = set()
    for path in required_paths:
        canonical = None
        if isinstance(path, str) and path.startswith("/") and path != "/":
            try:
                canonical = "/" + str(PurePosixPath(path).relative_to("/"))
            except ValueError:
                pass
        if canonical != path or ".." in PurePosixPath(path or "/").parts:
            failures.append(f"{path}: invalid-absolute-path")
        elif path in seen:
            failures.append(f"{path}: duplicate")
        elif path not in inventory:
            failures.append(f"{path}: missing-or-not-ELF")
        else:
            seen.add(path)
            seeds.add(path)
    if failures:
        report("ELF prune required dynamic root failures", failures)
        raise AuditError("declared dynamic ELF roots are incomplete")
    return seeds


def declared_closure(inventory, seeds):
    providers = defaultdict(set)
    for path, item in inventory.items():
        names = set(item["sonames"])
        names.add(Path(path).name)
        for name in names:
            providers[name].add(path)

    closure = set(seeds)
    pending = deque(byte_sorted(seeds))
    while pending:
        path = pending.popleft()
        for needed in inventory[path]["needed"]:
            for provider in byte_sorted(providers.get(needed, ())):
                if provider not in closure:
                    closure.add(provider)
                    pending.append(provider)
    return closure


def load_statuses(root, probe, inventory):
    inside_probe = "/tmp/elf-load-probe-prune"
    probe_target = root / inside_probe.lstrip("/")
    if probe_target.exists() or probe_target.is_symlink():
        raise AuditError(f"temporary loader probe path already exists: {inside_probe}")
    probe_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(probe, probe_target)
    probe_target.chmod(0o755)
    statuses = {}
    try:
        for inside in byte_sorted(inventory):
            environment = {
                "LC_ALL": "C",
                "OPENSSL_CONF": "/etc/pki/tls/openssl-guacd.cnf",
                "OPENSSL_MODULES": "/usr/lib64/ossl-modules",
                "LD_BIND_NOW": "1",
            }
            if inside == "/usr/sbin/guacd":
                environment["HOME"] = "/home/nonroot"
                command = [
                    "/usr/sbin/chroot", "--userspec=65532:65532", str(root),
                    "/usr/sbin/guacd", "-v",
                ]
            else:
                command = ["/usr/sbin/chroot", str(root), inside_probe, inside]
            result = subprocess.run(
                command,
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            statuses[inside] = result.returncode
    finally:
        probe_target.unlink(missing_ok=True)
    return statuses


def matching_requirement_packages(requirements, names):
    packages = set()
    for requirement, owners in requirements.items():
        if any(requirement == name or requirement.startswith(name + "(") for name in names):
            packages.update(owners)
    return byte_sorted(packages)


def owner_for(root, path):
    rendered = rpm_query(root, "-qf", path, "--qf", "%{NEVRA}\n")
    owners = byte_sorted(set(rendered.splitlines()))
    if len(owners) != 1:
        raise AuditError(f"{path}: expected one RPM owner, got {len(owners)}")
    return owners[0]


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--rootfs", required=True, type=Path)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--application-package", default="guacamole-server")
    parser.add_argument("--required-elf", action="append", default=[])
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)

    try:
        root = rootfs_root(args.rootfs)
        if not args.probe.is_file():
            raise AuditError(f"loader probe is not a regular file: {args.probe}")
        inventory = elf_inventory(root)
        requirements = requirement_owners(root)
        application_elf_seeds = application_seeds(
            root, inventory, args.application_package
        )
        dynamic_elf_seeds = required_elf_seeds(inventory, args.required_elf)
        seeds = application_elf_seeds | dynamic_elf_seeds
        closure = declared_closure(inventory, seeds)
        statuses = load_statuses(root, args.probe, inventory)
        failing = byte_sorted(path for path, status in statuses.items() if status != 0)

        records = []
        ownership_failures = []
        required_by_rpm = []
        required_by_elf = []
        closure_failures = []
        for path in failing:
            item = inventory[path]
            sonames = byte_sorted(set(item["sonames"]))
            capability_names = set(sonames or (Path(path).name,))
            capability_names.add(path)
            package_consumers = matching_requirement_packages(requirements, capability_names)
            elf_consumers = byte_sorted(
                other for other, other_item in inventory.items()
                if other != path and capability_names.intersection(other_item["needed"])
            )
            try:
                owner = owner_for(root, path)
            except AuditError as error:
                owner = None
                ownership_failures.append(str(error))
            in_closure = path in closure
            if package_consumers:
                required_by_rpm.append(f"{path}|required-by={','.join(package_consumers)}")
            if elf_consumers:
                required_by_elf.append(f"{path}|needed-by={','.join(elf_consumers)}")
            if in_closure:
                closure_failures.append(path)
            records.append({
                "path": path,
                "owner": owner,
                "sonames": sonames,
                "load_status": statuses[path],
                "package_required_by": package_consumers,
                "elf_needed_by": elf_consumers,
                "declared_rdp_closure": in_closure,
                "reason": (
                    "loader-failed; rpm-required-by=0; elf-needed-by=0; "
                    "outside-guacd-rdp-closure"
                ),
            })

        report("ELF prune loader failures", failing)
        if ownership_failures or required_by_rpm or required_by_elf or closure_failures:
            report("ELF prune ownership failures", ownership_failures)
            report("ELF prune RPM requirement failures", required_by_rpm)
            report("ELF prune DT_NEEDED failures", required_by_elf)
            report("ELF prune declared closure failures", closure_failures)
            raise AuditError("unloadable ELF intersects a required runtime surface")

        for record in records:
            path = record["path"]
            inventory[path]["entry"].path.unlink()
            print(
                f"ELF prune removed path={path} owner={record['owner']} "
                f"reason={record['reason']}"
            )

        remaining = elf_inventory(root)
        document = {
            "version": 1,
            "application_package": args.application_package,
            "inventory_before": len(inventory),
            "inventory_after": len(remaining),
            "application_elf_seeds": byte_sorted(application_elf_seeds),
            "declared_dynamic_elf_seeds": byte_sorted(dynamic_elf_seeds),
            "declared_elf_seeds": byte_sorted(seeds),
            "declared_runtime_closure": byte_sorted(closure),
            "loader_failures_before": failing,
            "removed": records,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"ELF prune complete removed={len(records)} retained={len(remaining)}")
        return 0
    except (AuditError, OSError) as error:
        print(f"ELF prune failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
