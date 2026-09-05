#!/usr/bin/env python3
"""Resolve and walk paths using rootfs/chroot rather than host symlink semantics."""
from __future__ import annotations

import os
import stat
from collections import deque
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterator


DEFAULT_SYMLINK_LIMIT = 40


class RootfsPathError(RuntimeError):
    """A rootfs path could not be resolved safely."""


class RootfsEscapeError(RootfsPathError):
    """A path attempted to walk above the rootfs root."""


class RootfsSymlinkCycleError(RootfsPathError):
    """A rootfs symlink expansion repeated the same resolution state."""


class RootfsSymlinkLimitError(RootfsPathError):
    """A rootfs path exceeded the allowed number of symlink traversals."""


@dataclass(frozen=True)
class RootfsEntry:
    """One lexically present rootfs entry, without following its final symlink."""

    path: Path
    relative: PurePosixPath
    stat: os.stat_result


def rootfs_root(root: Path | str) -> Path:
    """Return the canonical host path of the root directory itself."""
    canonical = Path(root).resolve(strict=True)
    if not canonical.is_dir():
        raise RootfsPathError(f"rootfs is not a directory: {root}")
    return canonical


def _components(path: Path | PurePosixPath | str) -> list[str]:
    """Split a rootfs path without discarding meaningful ``..`` components."""
    return [part for part in str(path).split("/") if part not in ("", ".")]


def resolve_rootfs_path(
    root: Path | str,
    path: Path | PurePosixPath | str,
    *,
    follow_final_symlink: bool = True,
    symlink_limit: int = DEFAULT_SYMLINK_LIMIT,
) -> PurePosixPath | None:
    """Resolve *path* from *root* and return a root-relative path.

    Absolute symlink targets restart at *root*. Relative targets are expanded
    from the link's containing directory. Missing targets, including dangling
    final symlinks when ``follow_final_symlink`` is true, return ``None``.
    """
    canonical_root = rootfs_root(root)
    original = str(path)
    pending = deque(_components(path))
    resolved: list[str] = []
    traversals = 0
    symlink_states: set[tuple[tuple[str, ...], str, tuple[str, ...]]] = set()

    while pending:
        component = pending.popleft()
        if component == "..":
            if not resolved:
                raise RootfsEscapeError(f"path escaped rootfs: {original}")
            resolved.pop()
            continue

        candidate = canonical_root.joinpath(*resolved, component)
        try:
            info = candidate.lstat()
        except (FileNotFoundError, NotADirectoryError):
            return None

        is_final = not pending
        if stat.S_ISLNK(info.st_mode) and (follow_final_symlink or not is_final):
            state = (tuple(resolved), component, tuple(pending))
            if state in symlink_states:
                raise RootfsSymlinkCycleError(f"symlink cycle in rootfs path: {original}")
            symlink_states.add(state)
            traversals += 1
            if traversals > symlink_limit:
                raise RootfsSymlinkLimitError(
                    f"too many symlink traversals in rootfs path: {original} "
                    f"(limit {symlink_limit})"
                )
            target = os.readlink(candidate)
            target_components = _components(target)
            if target.startswith("/"):
                resolved.clear()
            pending.extendleft(reversed(target_components))
            continue

        resolved.append(component)

    return PurePosixPath(*resolved)


def lstat_rootfs_path(
    root: Path | str,
    path: Path | PurePosixPath | str,
    *,
    symlink_limit: int = DEFAULT_SYMLINK_LIMIT,
) -> RootfsEntry | None:
    """Return an entry after resolving parent links but not the final link."""
    canonical_root = rootfs_root(root)
    relative = resolve_rootfs_path(
        canonical_root,
        path,
        follow_final_symlink=False,
        symlink_limit=symlink_limit,
    )
    if relative is None:
        return None
    candidate = canonical_root / relative
    try:
        info = candidate.lstat()
    except (FileNotFoundError, NotADirectoryError):
        return None
    return RootfsEntry(candidate, relative, info)


def stat_rootfs_path(
    root: Path | str,
    path: Path | PurePosixPath | str,
    *,
    symlink_limit: int = DEFAULT_SYMLINK_LIMIT,
) -> RootfsEntry | None:
    """Return the final entry after fully chroot-relative symlink resolution."""
    canonical_root = rootfs_root(root)
    relative = resolve_rootfs_path(
        canonical_root,
        path,
        symlink_limit=symlink_limit,
    )
    if relative is None:
        return None
    candidate = canonical_root / relative
    try:
        info = candidate.lstat()
    except (FileNotFoundError, NotADirectoryError):
        return None
    return RootfsEntry(candidate, relative, info)


def destination_rootfs_path(
    root: Path | str,
    path: Path | PurePosixPath | str,
    *,
    symlink_limit: int = DEFAULT_SYMLINK_LIMIT,
) -> tuple[Path, PurePosixPath]:
    """Locate a possibly absent final entry beneath a safely resolved parent."""
    canonical_root = rootfs_root(root)
    components = _components(path)
    if not components:
        return canonical_root, PurePosixPath()
    name = components.pop()
    if name == "..":
        raise RootfsEscapeError(f"path escaped rootfs: {path}")
    parent_text = "/" + "/".join(components)
    parent = resolve_rootfs_path(
        canonical_root,
        parent_text,
        symlink_limit=symlink_limit,
    )
    if parent is None:
        raise RootfsPathError(f"rootfs parent does not exist: {path}")
    relative = parent / name
    return canonical_root / relative, relative


def walk_rootfs(root: Path | str) -> Iterator[RootfsEntry]:
    """Yield every rootfs entry bytewise, never following directory symlinks."""
    canonical_root = rootfs_root(root)

    def walk(directory: Path, relative: PurePosixPath) -> Iterator[RootfsEntry]:
        with os.scandir(directory) as scan:
            entries = sorted(scan, key=lambda item: os.fsencode(item.name))
        for item in entries:
            item_relative = relative / item.name
            info = item.stat(follow_symlinks=False)
            entry = RootfsEntry(Path(item.path), item_relative, info)
            yield entry
            if stat.S_ISDIR(info.st_mode):
                yield from walk(entry.path, item_relative)

    yield from walk(canonical_root, PurePosixPath())
