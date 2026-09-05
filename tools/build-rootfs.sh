#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "FAILED rc=%s at %s:%s: %s\n" "$?" "${BASH_SOURCE[0]:-$0}" "$LINENO" "$BASH_COMMAND" >&2' ERR
export LC_ALL=C
source /workspace/tools/clean-package-manager-artifacts.sh
source /workspace/tools/finalize-rpmdb.sh

arch=${1:-amd64}
case "$arch" in
    amd64) rpm_arch=x86_64 ;;
    arm64) rpm_arch=aarch64 ;;
    *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
esac
case "$arch" in
    amd64) lock_sha256=b5ea65ec897319df13d01a229a8d6714482a150a075d3a3a5d3e45dfcd90fe76 ;;
    arm64) lock_sha256=dd576cf282257f20bf03202ddda7f7e76363d847fbd8f643e92792a2f001bc0a ;;
esac
rootfs=/rootfs
parent=/parent
lock="/workspace/rpm-lock/closure.${arch}.txt"
floor=/workspace/rpm-lock/parent-floor.json
(cd /workspace && tools/generate-closure-lock.sh --validate "$arch")

printf '%s  %s\n' "$lock_sha256" "$lock" | sha256sum --check --status
grep -Fx '%_install_langs C.utf8' /etc/rpm/macros.image-language-conf >/dev/null

mapfile -t expected_floor < <(jq -r --arg arch "$arch" '.parent.floor[$arch][][0]' "$floor" | sort)
mapfile -t actual_floor < <(rpm --root="$parent" -qa --qf '%{NEVRA}\n' | sort)
mapfile -t parent_floor_mismatches < <(
    comm -3 <(printf '%s\n' "${expected_floor[@]}") <(printf '%s\n' "${actual_floor[@]}")
)
if [[ ${#parent_floor_mismatches[@]} -ne 0 ]]; then
    printf 'parent floor package mismatches count=%s\n' "${#parent_floor_mismatches[@]}" >&2
    printf '%s\n' "${parent_floor_mismatches[@]}" >&2
    echo 'parent floor changed; run tools/generate-closure-lock.sh --refresh-parent' >&2
    exit 10
fi
parent_rpmdb_sha256=$(jq -er --arg arch "$arch" '.parent.rpmdb_sha256[$arch]' "$floor")
printf '%s  %s\n' "$parent_rpmdb_sha256" "$parent/var/lib/rpm/rpmdb.sqlite" | \
    sha256sum --check --status
test ! -e "$parent/usr/lib64/ossl-modules/legacy.so"
fips_sha256=$(jq -er --arg arch "$arch" '.fips.fips_so_sha256[$arch]' "$floor")
printf '%s  %s\n' "$fips_sha256" "$parent/usr/lib64/ossl-modules/fips.so" | \
    sha256sum --check --status
guac01_finalize_rpmdb "$parent" "${#actual_floor[@]}"
guac01_clean_package_manager_artifacts "$parent"

mkdir -p "$rootfs" /work
cp -a "$parent"/. "$rootfs"/

mapfile -t closure_rpms < <(awk -F '|' '!/^#/ {n=split($5,p,"/"); print "/a/rpms/" p[n]}' "$lock")
mapfile -t support_rpms < <(awk -F '|' '!/^#/ && $2=="no" {n=split($5,p,"/"); print "/a/rpms/" p[n]}' "$lock")
assembly_rpm_count=$((${#actual_floor[@]} + ${#closure_rpms[@]} + 1))
support=()
for rpm_file in "${support_rpms[@]}"; do
    support+=("$(rpm -qp --qf '%{NAME}' "$rpm_file")")
done
if [[ ${#support[@]} -ne 15 ]]; then
    echo "support package count mismatch: expected 15, got ${#support[@]}" >&2
    exit 13
fi
guac_rpm="/a/guacamole-server-1.6.0-1.el9.${rpm_arch}.rpm"
overlap_args=()
for rpm_file in "${closure_rpms[@]}" "$guac_rpm"; do overlap_args+=(--rpm "$rpm_file"); done
python3 /workspace/tools/parent-overlap.py --parent "$parent" --output /work/parent-overlap.txt \
    "${overlap_args[@]}"

rpm --root="$rootfs" -Uvh --noscripts --notriggers --nosignature --oldpackage --replacepkgs \
    --excludedocs "${closure_rpms[@]}" "$guac_rpm"
actual_assembly_rpm_count=$(rpm --root="$rootfs" -qa | wc -l)
if [[ $actual_assembly_rpm_count -ne $assembly_rpm_count ]]; then
    echo "assembled rpmdb count mismatch: expected $assembly_rpm_count, got $actual_assembly_rpm_count" >&2
    exit 12
fi

expected_scriptlets='bash fontconfig freetype glib2 krb5-libs libblkid p11-kit-trust systemd-libs xml-common'
script_query='%|PREIN?{%{PREIN}}:{}|%|POSTIN?{%{POSTIN}}:{}|%|PREUN?{%{PREUN}}:{}|%|POSTUN?{%{POSTUN}}:{}|%|PRETRANS?{%{PRETRANS}}:{}|%|POSTTRANS?{%{POSTTRANS}}:{}|%|TRIGGERSCRIPTS?{[%{TRIGGERSCRIPTS}]}:{}|%|FILETRIGGERSCRIPTS?{[%{FILETRIGGERSCRIPTS}]}:{}|%|TRANSFILETRIGGERSCRIPTS?{[%{TRANSFILETRIGGERSCRIPTS}]}:{}|'
: > /work/scriptlets.txt
nonempty=()
unclassified_scriptlets=()
for rpm_file in "${closure_rpms[@]}" "$guac_rpm"; do
    name=$(rpm -qp --qf '%{NAME}' "$rpm_file")
    script_payload=$(rpm -qp --qf "$script_query" "$rpm_file")
    if [[ -n "$script_payload" ]]; then
        nonempty+=("$name")
        printf '## %s\n' "$name" >> /work/scriptlets.txt
        # Human-formatted output is evidence only; no gate parses its wording.
        for query in --scripts --triggers --filetriggers; do
            printf '### %s\n' "$query" >> /work/scriptlets.txt
            rpm -qp "$query" "$rpm_file" >> /work/scriptlets.txt 2>&1 || true
        done
        if ! grep -Fx "## $name" /workspace/rpm-lock/scriptlet-classification.md >/dev/null; then
            unclassified_scriptlets+=("$name")
        fi
    fi
done
actual_scriptlets=$(printf '%s\n' "${nonempty[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//')
if [[ "$actual_scriptlets" != "$expected_scriptlets" || ${#unclassified_scriptlets[@]} -ne 0 ]]; then
    comm -3 <(tr ' ' '\n' <<< "$expected_scriptlets" | sort -u) \
        <(printf '%s\n' "${nonempty[@]}" | sort -u) | sed 's/^/scriptlet-set-mismatch: /' >&2
    printf 'unclassified-scriptlets count=%s\n' "${#unclassified_scriptlets[@]}" >&2
    printf '%s\n' "${unclassified_scriptlets[@]}" | sort -u >&2
    exit 11
fi

protected_args=()
for package in "${support[@]}"; do protected_args+=(--support-package "$package"); done
runtime_elf_seeds=(
    /usr/lib64/libnss_dns.so.2
    /usr/lib64/libnss_files.so.2
    /usr/lib64/libnss_myhostname.so.2
)
if [[ ${#runtime_elf_seeds[@]} -eq 0 ]] || \
        ! printf '%s\n' "${runtime_elf_seeds[@]}" | LC_ALL=C sort -cu; then
    echo 'runtime ELF seed contract is empty, duplicated, or not bytewise sorted' >&2
    exit 21
fi
runtime_elf_args=()
for path in "${runtime_elf_seeds[@]}"; do runtime_elf_args+=(--required-elf "$path"); done
python3 /workspace/tools/protected-paths.py --rootfs "$rootfs" \
    "${protected_args[@]}" "${runtime_elf_args[@]}" --output /work/protected-paths.json

rpm --root="$rootfs" -e --nodeps --noscripts --notriggers "${support[@]}"
installed_names=$(rpm --root="$rootfs" -qa --qf '%{NAME}\n')
remaining_support=()
for package in "${support[@]}"; do
    if grep -Fx "$package" <<< "$installed_names" >/dev/null; then
        remaining_support+=("$package")
    fi
done
if [[ ${#remaining_support[@]} -ne 0 ]]; then
    printf 'support packages remaining count=%s\n' "${#remaining_support[@]}" >&2
    printf '%s\n' "${remaining_support[@]}" | sort -u >&2
    exit 14
fi
expected_image_rpm_count=$((assembly_rpm_count - ${#support[@]}))
guac01_finalize_rpmdb "$rootfs" "$expected_image_rpm_count" | \
    tee /work/rpmdb-finalization.txt

python3 /workspace/tools/restore-parent.py --parent "$parent" --rootfs "$rootfs"

rm -rf /openssl-extract
mkdir -p /openssl-extract
rpm --root=/openssl-extract --initdb
legacy_rpm="/a/rpms/openssl-libs-3.5.5-5.el9_8.${rpm_arch}.rpm"
rpm --root=/openssl-extract -i --nodeps --noscripts --notriggers --excludedocs --nosignature "$legacy_rpm"
install -D -m 0755 /openssl-extract/usr/lib64/ossl-modules/legacy.so \
    "$rootfs/usr/lib64/ossl-modules/legacy.so"
chown 0:0 "$rootfs/usr/lib64/ossl-modules/legacy.so"
if [[ "$arch" == amd64 ]]; then
    legacy_hash=c6b40ba5f7f90d37601995e68d834d5d6b68896b1a7114db3bd08755825d2e95
else
    legacy_hash=3aaa9b813da8bba767e4be12bf6b72852722a503a1bdfe894ff272ae96ee6ff4
fi
printf '%s  %s\n' "$legacy_hash" "$rootfs/usr/lib64/ossl-modules/legacy.so" | \
    sha256sum --check --status
rpm --root="$rootfs" -ql openssl-libs | \
    grep -Fx '/usr/lib64/ossl-modules/legacy.so' >/dev/null || {
        echo 'openssl-libs rpmdb ownership is missing for legacy.so' >&2
        exit 15
    }
install -D -m 0644 /c0/containers/openssl/openssl-guacd.cnf "$rootfs/etc/pki/tls/openssl-guacd.cnf"
install -D -m 0644 /c0/containers/fips-status.json "$rootfs/etc/nwarila/fips-status.json"
install -m 0644 /c0/SECURITY.md "$rootfs/SECURITY.md"

: > /work/retained-payload-trim.txt
trim_resolution_failures=()
for rpm_file in "${closure_rpms[@]}"; do
    final=$(awk -F '|' -v url="$(basename "$rpm_file")" '!/^#/ && $5 ~ ("/" url "$") {print $2}' "$lock")
    [[ "$final" == yes ]] || continue
    name=$(rpm -qp --qf '%{NAME}' "$rpm_file")
    package_paths=$(rpm --root="$rootfs" -ql "$name")
    while IFS= read -r path; do
        case "$path" in
            /usr/bin/*|/usr/sbin/*|/usr/libexec/*|/usr/share/bash-completion/*|/usr/share/zsh/*|/usr/share/fish/*)
                target_status=0
                if target=$(python3 /workspace/tools/rootfs-path-check.py --root "$rootfs" \
                        --path "$path" --kind regular-or-symlink --no-follow-final \
                        --print-host-path); then
                    printf '%s|%s\n' "$name" "$path" >> /work/retained-payload-trim.txt
                    rm -f "$target"
                else
                    target_status=$?
                    if [[ $target_status -ne 1 ]]; then
                        trim_resolution_failures+=("$name|$path|status=$target_status")
                    fi
                fi
                ;;
        esac
    done <<< "$package_paths"
done
if [[ ${#trim_resolution_failures[@]} -ne 0 ]]; then
    printf 'retained path resolution failures count=%s\n' "${#trim_resolution_failures[@]}" >&2
    printf '%s\n' "${trim_resolution_failures[@]}" | sort -u >&2
    exit 19
fi

if find "$rootfs/usr/bin" -mindepth 1 \( -type f -o -type l \) | grep .; then
    echo 'runtime rootfs contains a file or symlink under /usr/bin' >&2
    exit 16
fi
mapfile -t shipped_sbin < <(find "$rootfs/usr/sbin" -mindepth 1 \( -type f -o -type l \) -printf '%f\n' | sort)
if [[ "${shipped_sbin[*]}" != guacd ]]; then
    echo "runtime /usr/sbin shape mismatch: expected guacd, got ${shipped_sbin[*]:-<empty>}" >&2
    exit 17
fi
mapfile -t forbidden_commands < <(find "$rootfs/bin" "$rootfs/sbin" \
    "$rootfs/usr/bin" "$rootfs/usr/sbin" \( -type f -o -type l \) \
    \( -name sh -o -name bash -o -name dash -o -name ash -o -name busybox \
       -o -name ksh -o -name zsh -o -name tcsh -o -name csh -o -name dnf \
       -o -name microdnf -o -name rpm -o -name yum -o -name python \
       -o -name python3 -o -name python3.12 -o -name gs \) -print 2>/dev/null | sort -u)
if [[ ${#forbidden_commands[@]} -ne 0 ]]; then
    printf 'runtime forbidden commands count=%s\n' "${#forbidden_commands[@]}" >&2
    printf '%s\n' "${forbidden_commands[@]}" >&2
    exit 18
fi

ldconfig -r "$rootfs"
test -s "$rootfs/etc/ld.so.cache"
python3 /workspace/tools/prune-unused-elf.py --rootfs "$rootfs" \
    --probe /a/elf-load-probe --application-package guacamole-server \
    "${runtime_elf_args[@]}" \
    --output /work/unused-elf-prune.json
# The pre-prune cache is assembly input to the loader audit. Rebuild it after
# removal so no cache entry describes an ELF that the derived audit discarded.
ldconfig -r "$rootfs"
test -s "$rootfs/etc/ld.so.cache"

guac01_clean_package_manager_artifacts "$rootfs"
find "$rootfs" -xdev -exec touch -h -d "@${SOURCE_DATE_EPOCH:-1704067200}" {} +

actual_image_rpm_count=$(rpm --root="$rootfs" -qa | wc -l)
if [[ $actual_image_rpm_count -ne $expected_image_rpm_count ]]; then
    echo "final rpmdb count mismatch: expected $expected_image_rpm_count, got $actual_image_rpm_count" >&2
    exit 20
fi
rpm --root="$rootfs" --verifydb
rpm --root="$rootfs" -qa --qf '%{NEVRA}\n' | sort > /work/image-manifest.txt
printf '%s\n' "$actual_image_rpm_count" > /work/expected-image-rpm-count.txt
guac01_release_closed_rpmdb_artifacts "$rootfs"
guac01_clean_package_manager_artifacts "$rootfs"
