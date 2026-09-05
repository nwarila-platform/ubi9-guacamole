#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "FAILED rc=%s at %s:%s: %s\n" "$?" "${BASH_SOURCE[0]:-$0}" "$LINENO" "$BASH_COMMAND" >&2' ERR
export LC_ALL=C

mode=${1:-}
case "$mode" in
    --validate)
        arch=${2:-amd64}
        lock="rpm-lock/closure.${arch}.txt"
        case "$arch" in
            amd64) rpm_arch=x86_64 ;;
            arm64) rpm_arch=aarch64 ;;
            *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
        esac
        validation_failures=()
        if ! jq -e --arg arch "$arch" --arg rpm_arch "$rpm_arch" '
          .version == 1 and
          .walk_parent_requirements == false and
          .install_weak_deps == false and
          .accepted_candidate_arches[$arch] == [$rpm_arch,"noarch"] and
          .origin_preference == ["ubi9","centos-stream"] and
          .ambiguity == "fail" and .parent_name_overlap == "fail"
        ' rpm-lock/resolver-policy.json >/dev/null; then
            validation_failures+=("resolver-policy: contract-mismatch")
        fi
        row_count=$(awk -F '|' '!/^#/ {n++} END {print n+0}' "$lock")
        ubi_count=$(awk -F '|' '!/^#/ && $3=="ubi9" {n++} END {print n+0}' "$lock")
        centos_count=$(awk -F '|' '!/^#/ && $3=="centos-stream" {n++} END {print n+0}' "$lock")
        [[ $row_count -eq 89 ]] || validation_failures+=("row-count: expected=89 got=$row_count")
        [[ $ubi_count -eq 86 ]] || validation_failures+=("ubi9-row-count: expected=86 got=$ubi_count")
        [[ $centos_count -eq 3 ]] || validation_failures+=("centos-row-count: expected=3 got=$centos_count")
        while IFS= read -r failure; do
            validation_failures+=("forbidden-row: $failure")
        done < <(grep -nE '\.i686\||^findutils-' "$lock" || true)
        while IFS= read -r failure; do
            validation_failures+=("noncanonical-order: $failure")
        done < <(awk -F '|' '!/^#/ {
            if (seen && $1 < previous) print "line=" NR " value=" $1 " previous=" previous;
            previous=$1; seen=1
        }' "$lock")
        if [[ ${#validation_failures[@]} -ne 0 ]]; then
            printf 'closure lock validation failures count=%s\n' "${#validation_failures[@]}" >&2
            printf '%s\n' "${validation_failures[@]}" | sort >&2
            exit 4
        fi
        ;;
    --refresh-parent)
        echo 'refresh is review-only: resolve with the pinned policy, replace both literal locks, then run --validate for each architecture' >&2
        exit 2
        ;;
    *)
        echo "usage: $0 --validate <amd64|arm64> | --refresh-parent" >&2
        exit 2
        ;;
esac
