#!/usr/bin/env bash
# Safely checkpoint and close a retained SQLite rpmdb before rootfs inventories.

set -E
if [[ -z $(trap -p ERR) ]]; then
trap 'printf "FAILED rc=%s at %s:%s: %s\n" "$?" "${BASH_SOURCE[0]:-$0}" "$LINENO" "$BASH_COMMAND" >&2' ERR
fi

guac01_rpmdb_package_count() {
    local tree=$1 count

    if count=$(set -o pipefail; rpm --root="$tree" -qa | wc -l); then
        :
    else
        echo "failed to count packages in retained rpmdb: $tree" >&2
        return 1
    fi
    count=${count//[[:space:]]/}
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        echo "invalid retained rpmdb package count: ${count:-<empty>}" >&2
        return 1
    fi
    printf '%s\n' "$count"
}

guac01_release_closed_rpmdb_artifacts() {
    local tree=$1
    local database="$tree/var/lib/rpm/rpmdb.sqlite"
    local lock="$tree/var/lib/rpm/.rpm.lock"
    local hash_before_line hash_before hash_after_line hash_after

    if [[ ! -s "$database" || -L "$database" ]]; then
        echo "retained rpmdb is missing, empty, or a symlink: $database" >&2
        return 1
    fi
    hash_before_line=$(sha256sum -- "$database")
    hash_before=${hash_before_line%% *}
    python3 - "$database" "$lock" <<'PY'
import errno
import fcntl
import os
import sqlite3
import sys

database, lock = sys.argv[1:]
uri = "file:" + database + "?mode=rw"
with sqlite3.connect(uri, uri=True, timeout=30) as connection:
    journal = connection.execute("PRAGMA journal_mode").fetchone()[0].lower()
if journal != "delete":
    raise SystemExit(f"retained rpmdb journal mode is not finalized: {journal}")

# Every rpm client in the build is a foreground subprocess. Acquire both BSD
# and POSIX advisory locks before unlinking the now-inactive pathname so a
# future caller cannot mistake removal of a live lock for cleanup.
if os.path.lexists(lock):
    descriptor = os.open(lock, os.O_RDWR | os.O_CLOEXEC)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EAGAIN):
                raise SystemExit(f"retained rpmdb lock is still held: {lock}") from error
            raise
        os.unlink(lock)
    finally:
        os.close(descriptor)

for suffix in ("-wal", "-shm"):
    sidecar = database + suffix
    if os.path.lexists(sidecar):
        raise SystemExit(f"retained rpmdb sidecar remains after clean close: {sidecar}")
if os.path.lexists(lock):
    raise SystemExit(f"retained rpmdb lock remains after clean close: {lock}")
PY
    hash_after_line=$(sha256sum -- "$database")
    hash_after=${hash_after_line%% *}
    if [[ "$hash_before" != "$hash_after" ]]; then
        echo "retained rpmdb changed while releasing its closed lock" >&2
        return 1
    fi
}

guac01_finalize_rpmdb() {
    local tree=$1 expected_count=${2:-}
    local database="$tree/var/lib/rpm/rpmdb.sqlite"
    local count_before count_after checkpoint_result
    local stable_hash_line stable_hash stable_hash_after_line stable_hash_after

    count_before=$(guac01_rpmdb_package_count "$tree")
    checkpoint_result=$(python3 - "$database" <<'PY'
import sqlite3
import sys

database = sys.argv[1]
uri = "file:" + database + "?mode=rw"
with sqlite3.connect(uri, uri=True, timeout=30) as connection:
    journal_before = connection.execute("PRAGMA journal_mode").fetchone()[0].lower()
    checkpoint = "not-required"
    if journal_before == "wal":
        result = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        if result[0] != 0:
            raise SystemExit(f"retained rpmdb checkpoint remained busy: {result!r}")
        checkpoint = ",".join(map(str, result))
    journal_after = connection.execute("PRAGMA journal_mode=DELETE").fetchone()[0].lower()
    if journal_after != "delete":
        raise SystemExit(f"failed to finalize retained rpmdb journal mode: {journal_after}")
print(f"journal-before={journal_before} checkpoint={checkpoint} journal-after={journal_after}")
PY
    )

    # Once the WAL is folded into the main database and DELETE mode is durable,
    # a read-only RPM query must leave both the package set and main-db bytes
    # unchanged. This also proves future gate queries cannot recreate WAL/SHM.
    stable_hash_line=$(sha256sum -- "$database")
    stable_hash=${stable_hash_line%% *}
    count_after=$(guac01_rpmdb_package_count "$tree")
    stable_hash_after_line=$(sha256sum -- "$database")
    stable_hash_after=${stable_hash_after_line%% *}

    if [[ "$count_before" -ne "$count_after" ]]; then
        echo "retained rpmdb package count changed during finalization: before=$count_before after=$count_after" >&2
        return 1
    fi
    if [[ -n "$expected_count" && "$count_after" -ne "$expected_count" ]]; then
        echo "final retained rpmdb package count mismatch: expected=$expected_count got=$count_after" >&2
        return 1
    fi
    if [[ "$stable_hash" != "$stable_hash_after" ]]; then
        echo "retained rpmdb bytes changed after its final read-only package query" >&2
        return 1
    fi

    guac01_release_closed_rpmdb_artifacts "$tree"
    printf 'rpmdb-finalized packages-before=%s packages-after=%s %s\n' \
        "$count_before" "$count_after" "$checkpoint_result"
}
