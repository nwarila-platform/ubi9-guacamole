#!/usr/bin/env bash

set -E
if [[ -z $(trap -p ERR) ]]; then
trap 'printf "FAILED rc=%s at %s:%s: %s\n" "$?" "${BASH_SOURCE[0]:-$0}" "$LINENO" "$BASH_COMMAND" >&2' ERR
fi

# Shared trust records and assertions for the RPM keys consumed by G0 and by
# the system-rpmdb import which precedes installation of G0-verified RPMs.
rpm_key_record() {
    case "$1" in
        centos)
            printf '%s\n' \
                '/workspace/containers/keys/RPM-GPG-KEY-CentOS-Official 146059788b214d7ba0dd70c1cf21111e594c6cfde201da8a9a88fe7101be8a78 8483c65d 05B555B38483C65D 1556896537 99DB70FAE1D7CE227FB6488205B555B38483C65D'
            ;;
        redhat)
            printf '%s\n' \
                '/workspace/containers/keys/RPM-GPG-KEY-redhat-release-fd431d51.txt d4b2543626bee31d9438d4a31731aae712c072893c7aed8854f16c42fafc742b fd431d51 199E2F91FD431D51 1256212795 567E347AD0044ADE55BA8A5F199E2F91FD431D51'
            ;;
        *) return 2 ;;
    esac
}

rpm_key_primary_identity() {
    local gnupg=$1 file=$2
    gpg --batch --homedir "$gnupg" --show-keys --with-colons --with-fingerprint "$file" \
        2>/dev/null | awk -F: '
            $1 == "pub" { key_id=$5; created=$6; next }
            key_id != "" && $1 == "fpr" { print key_id "|" created "|" $10; found=1; exit }
            END { if (!found) exit 1 }
        '
}

rpm_key_file_matches() {
    local gnupg=$1 file=$2 expected_sha256=$3 expected_identity=$4
    printf '%s  %s\n' "$expected_sha256" "$file" | sha256sum --check --status || return 1
    local actual_identity
    if actual_identity=$(rpm_key_primary_identity "$gnupg" "$file"); then
        :
    else
        local identity_status=$?
        echo "RPM key primary identity query failed: file=$file status=$identity_status" >&2
        return 2
    fi
    if [[ "$actual_identity" != "$expected_identity" ]]; then
        echo "RPM key primary identity mismatch: file=$file" >&2
        return 3
    fi
}

rpm_key_assert_file() {
    local gnupg=$1 label=$2
    local file sha256 version key_id created fingerprint
    read -r file sha256 version key_id created fingerprint < <(rpm_key_record "$label") || return 1
    rpm_key_file_matches "$gnupg" "$file" "$sha256" "$key_id|$created|$fingerprint"
}

rpm_key_import() {
    local label=$1 db=${2:-}
    local file sha256 version key_id created fingerprint
    local -a db_args=()
    read -r file sha256 version key_id created fingerprint < <(rpm_key_record "$label") || return 1
    [[ -n "$db" ]] && db_args=(--dbpath "$db")
    rpmkeys "${db_args[@]}" --import "$file"
}

rpm_key_assert_imported() {
    local gnupg=$1 label=$2 db=${3:-} exclusive=${4:-no}
    local file sha256 version key_id created fingerprint packages matches identity
    local -a db_args=()
    read -r file sha256 version key_id created fingerprint < <(rpm_key_record "$label") || return 1
    [[ -n "$db" ]] && db_args=(--dbpath "$db")

    packages=$(rpm "${db_args[@]}" -qa --qf '%{NAME}|%{VERSION}\n') || return 1
    matches=$(awk -F '|' -v version="$version" \
        '$1 == "gpg-pubkey" && $2 == version' <<< "$packages")
    [[ "$matches" == "gpg-pubkey|$version" ]] || return 1
    if [[ "$exclusive" == yes ]]; then
        [[ "$packages" == "$matches" ]] || return 1
    fi

    identity=$(rpm "${db_args[@]}" -q "gpg-pubkey-$version" --qf '%{DESCRIPTION}\n' | \
        rpm_key_primary_identity "$gnupg" -) || return 1
    if [[ "$identity" != "$key_id|$created|$fingerprint" ]]; then
        echo "imported RPM key identity mismatch: label=$label" >&2
        return 4
    fi
}
