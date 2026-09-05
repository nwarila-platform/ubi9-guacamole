#!/usr/bin/env bash
# Shared removal policy for package-manager transaction artifacts.

set -E
if [[ -z $(trap -p ERR) ]]; then
trap 'printf "FAILED rc=%s at %s:%s: %s\n" "$?" "${BASH_SOURCE[0]:-$0}" "$LINENO" "$BASH_COMMAND" >&2' ERR
fi

guac01_remove_artifact_tree() {
    local path=$1
    if [[ -d "$path" && ! -L "$path" ]]; then
        find "$path" -xdev -depth -delete
    elif [[ -e "$path" || -L "$path" ]]; then
        rm -f -- "$path"
    fi
}

guac01_clean_package_manager_artifacts() {
    local tree=$1 directory path
    local -a artifacts=()

    # Keep /var/lib/rpm in its entirety: the shipped rpmdb is image content,
    # and its SQLite sidecars must be handled by finalize-rpmdb.sh while no
    # database handle is live.
    for directory in "$tree/var/cache" "$tree/var/lib"; do
        [[ -d "$directory" ]] || continue
        while IFS= read -r -d '' path; do
            artifacts+=("$path")
        done < <(find "$directory" -mindepth 1 -maxdepth 1 \
            \( -name 'dnf' -o -name 'dnf-*' -o -name 'yum' -o -name 'yum-*' \) \
            -print0)
    done
    if [[ -d "$tree/var/log" ]]; then
        while IFS= read -r -d '' path; do
            artifacts+=("$path")
        done < <(find "$tree/var/log" -mindepth 1 -maxdepth 1 \
            \( -name 'hawkey.log*' -o -name 'dnf*' -o -name 'microdnf*' \
               -o -name 'yum.log*' \) -print0)
    fi
    if [[ -d "$tree/var/tmp" ]]; then
        while IFS= read -r -d '' path; do
            artifacts+=("$path")
        done < <(find "$tree/var/tmp" -mindepth 1 -maxdepth 1 -print0)
    fi
    for path in "${artifacts[@]}"; do
        guac01_remove_artifact_tree "$path"
    done
}
