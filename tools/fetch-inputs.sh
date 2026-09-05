#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "FAILED rc=%s at %s:%s: %s\n" "$?" "${BASH_SOURCE[0]:-$0}" "$LINENO" "$BASH_COMMAND" >&2' ERR
export LC_ALL=C

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <inputs/rpms.ARCH.lock> <inputs/rpms.ARCH.sources>" >&2
    exit 2
fi

lock=$1
sources=$2
lock_count=$(awk '!/^#/ {n++} END {print n+0}' "$lock")
source_count=$(awk '!/^#/ {n++} END {print n+0}' "$sources")
if [[ "$lock_count" -ne 102 || "$source_count" -ne "$lock_count" ]]; then
    echo "input row count mismatch: lock=$lock_count sources=$source_count expected=102" >&2
    exit 4
fi
mkdir -p /out/rpms /out/source
manifest_failures=()
row=0
while IFS='|' read -r path origin digest key source_path url role; do
    row=$((row + 1))
    [[ "$path" == "$source_path" ]] || manifest_failures+=("row=$row lock-path=$path source-path=$source_path")
    case "$origin:$key" in
        centos-stream:8483c65d|ubi9:fd431d51) ;;
        *) manifest_failures+=("row=$row path=$path invalid-origin-key=$origin:$key") ;;
    esac
    case "$role" in
        closure|legacy-source|builder|debuginfo|assembler-bootstrap) ;;
        *) manifest_failures+=("row=$row path=$path invalid-role=$role") ;;
    esac
done < <(paste -d '|' <(awk '!/^#/' "$lock") <(awk '!/^#/' "$sources"))
if [[ ${#manifest_failures[@]} -ne 0 ]]; then
    printf 'input manifest mismatches count=%s\n' "${#manifest_failures[@]}" >&2
    printf '%s\n' "${manifest_failures[@]}" | sort >&2
    exit 3
fi

digest_failures=()
while IFS='|' read -r path _origin digest _key _source_path url _role; do
    mkdir -p "$(dirname "$path")"
    if [[ ! -f "$path" ]] || \
            ! printf '%s  %s\n' "$digest" "$path" | sha256sum --check --status; then
        curl --fail --silent --show-error --location --retry 4 --retry-delay 2 "$url" -o "$path"
    fi
    if ! printf '%s  %s\n' "$digest" "$path" | sha256sum --check --status; then
        digest_failures+=("$path")
    fi
done < <(paste -d '|' <(awk '!/^#/' "$lock") <(awk '!/^#/' "$sources"))
if [[ ${#digest_failures[@]} -ne 0 ]]; then
    printf 'input digest mismatches count=%s\n' "${#digest_failures[@]}" >&2
    printf '%s\n' "${digest_failures[@]}" | sort >&2
    exit 5
fi

curl --fail --silent --show-error --location --retry 4 --retry-delay 2 \
    https://archive.apache.org/dist/guacamole/1.6.0/source/guacamole-server-1.6.0.tar.gz \
    -o /out/source/guacamole-server-1.6.0.tar.gz
curl --fail --silent --show-error --location --retry 4 --retry-delay 2 \
    https://archive.apache.org/dist/guacamole/1.6.0/source/guacamole-server-1.6.0.tar.gz.asc \
    -o /out/source/guacamole-server-1.6.0.tar.gz.asc
