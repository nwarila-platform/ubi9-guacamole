#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "FAILED rc=%s at %s:%s: %s\n" "$?" "${BASH_SOURCE[0]:-$0}" "$LINENO" "$BASH_COMMAND" >&2' ERR
export LC_ALL=C

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <amd64|arm64> <rpm-directory>" >&2
    exit 2
fi
arch=$1
rpm_dir=$2
lock="/workspace/rpm-lock/builder.${arch}.txt"
case "$arch" in
    amd64|arm64) ;;
    *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
esac

direct_count=$(awk '/^# direct_rpm: / {n++} END {print n+0}' "$lock")
data_count=$(awk '!/^#/ {n++} END {print n+0}' "$lock")
direct_shape_errors=$(awk -F '|' '/^# direct_rpm: / && NF != 3 {n++} END {print n+0}' "$lock")
data_shape_errors=$(awk -F '|' '!/^#/ && NF != 8 {n++} END {print n+0}' "$lock")
if [[ "$direct_count" -ne 7 ]]; then
    echo "builder lock direct_rpm row count mismatch: expected 7, got $direct_count" >&2
    exit 3
fi
if [[ "$data_count" -ne 7 ]]; then
    echo "builder lock data row count mismatch: expected 7, got $data_count" >&2
    exit 4
fi
if [[ "$direct_shape_errors" -ne 0 || "$data_shape_errors" -ne 0 ]]; then
    echo "builder lock row shape mismatch: direct_rpm_errors=$direct_shape_errors data_errors=$data_shape_errors" >&2
    exit 5
fi

rpms=()
while IFS='|' read -r _marker url _digest; do
    rpms+=("$rpm_dir/$(basename "$url")")
done < <(grep '^# direct_rpm: ' "$lock")
if [[ ${#rpms[@]} -ne 7 ]]; then
    echo "builder bootstrap RPM list count mismatch after parsing: expected 7, got ${#rpms[@]}" >&2
    exit 6
fi
rpm -Uvh --nosignature --oldpackage --replacepkgs "${rpms[@]}"
if rpm_version=$(rpm -q rpm --qf '%{VERSION}|%{RELEASE}'); then
    :
else
    query_status=$?
    echo "failed to query installed rpm version: status=$query_status" >&2
    exit 7
fi
if [[ "$rpm_version" != '4.16.1.3|40.el9' ]]; then
    echo "installed rpm version mismatch: expected 4.16.1.3|40.el9, got $rpm_version" >&2
    exit 8
fi

bootstrap_failures=()
while IFS='|' read -r _package name epoch version release package_arch header sigmd5; do
    expected="$name|$epoch|$version|$release|$package_arch|$header|$sigmd5"
    if actual=$(rpm -q "$name" --qf '%{NAME}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}|%{ARCH}|%{SHA256HEADER}|%{SIGMD5}'); then
        :
    else
        query_status=$?
        bootstrap_failures+=("$name query-status=$query_status")
        continue
    fi
    if [[ "$actual" != "$expected" ]]; then
        bootstrap_failures+=("$name expected=$expected got=$actual")
    fi
done < <(grep -v '^#' "$lock")
if [[ ${#bootstrap_failures[@]} -ne 0 ]]; then
    printf 'assembler bootstrap mismatches count=%s\n' "${#bootstrap_failures[@]}" >&2
    printf '%s\n' "${bootstrap_failures[@]}" | sort >&2
    exit 10
fi

mkdir -p /usr/local/bin
ln -sfn /usr/bin/python3.12 /usr/local/bin/python3
python3 -c 'import sys; raise SystemExit(sys.version_info[:3] != (3, 12, 13))' || {
    echo 'python3 version mismatch: expected 3.12.13' >&2
    exit 11
}
