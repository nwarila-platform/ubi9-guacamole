#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "FAILED rc=%s at %s:%s: %s\n" "$?" "${BASH_SOURCE[0]:-$0}" "$LINENO" "$BASH_COMMAND" >&2' ERR
export LC_ALL=C
source /workspace/tools/rpm-key-trust.sh

arch=${1:-amd64}
case "$arch" in
    amd64) rpm_arch=x86_64 ;;
    arm64) rpm_arch=aarch64 ;;
    *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
esac

runtime_rpms=(
    "/out/rpms/freerdp-libs-2.11.7-12.el9.${rpm_arch}.rpm"
    "/out/rpms/libwinpr-2.11.7-12.el9.${rpm_arch}.rpm"
    "/out/rpms/freerdp-devel-2.11.7-12.el9.${rpm_arch}.rpm"
    "/out/rpms/libwinpr-devel-2.11.7-12.el9.${rpm_arch}.rpm"
    "/out/rpms/annobin-annocheck-13.28-1.el9.${rpm_arch}.rpm"
)
baseline_rpmdb=/var/lib/guac01-builder-base-rpmdb
if [[ ! -d "$baseline_rpmdb" ]]; then
    echo 'pinned builder base rpmdb snapshot is missing' >&2
    exit 19
fi

runtime_transaction_dir=$(mktemp -d /tmp/guac-runtime-rpm.XXXXXX)
trap 'rm -rf -- "$runtime_transaction_dir"' EXIT
probe_rpmdb="$runtime_transaction_dir/baseline-rpmdb"
cp -a "$baseline_rpmdb" "$probe_rpmdb"
key_gnupg="$runtime_transaction_dir/gnupg"
install -d -m 0700 "$key_gnupg"
for key_label in centos redhat; do
    rpm_key_assert_file "$key_gnupg" "$key_label"
    rpm_key_import "$key_label"
    rpm_key_assert_imported "$key_gnupg" "$key_label"
    rpm_key_import "$key_label" "$probe_rpmdb"
    rpm_key_assert_imported "$key_gnupg" "$key_label" "$probe_rpmdb"
done

# Check the locked local files against the now-trusted system rpmdb, then
# require RPM's normal dependency and signature checks.
rpmkeys --checksig "${runtime_rpms[@]}"

extract_unmet_capabilities() {
    local test_log=$1 output=$2
    sed -nE 's/^[[:space:]]*(.+) is needed by .+$/\1/p' "$test_log" | \
        LC_ALL=C sort -u > "$output"
}

initial_test_log="$runtime_transaction_dir/initial-test.log"
derived_capabilities="$runtime_transaction_dir/derived-capabilities.txt"
if rpm --dbpath "$probe_rpmdb" -Uvh --test "${runtime_rpms[@]}" \
        > "$initial_test_log" 2>&1; then
    initial_test_status=0
else
    initial_test_status=$?
fi
printf 'DEPENDENCY-PROBE runtime-rpm-closure completed (rc=%s)\n' "$initial_test_status"
extract_unmet_capabilities "$initial_test_log" "$derived_capabilities"

if [[ $initial_test_status -ne 0 && ! -s "$derived_capabilities" ]]; then
    echo 'initial runtime RPM transaction test failed without parseable unmet capabilities' >&2
    cat "$initial_test_log" >&2
    exit 20
fi
if [[ $initial_test_status -eq 0 && -s "$derived_capabilities" ]]; then
    echo 'initial runtime RPM transaction test succeeded but emitted unmet capabilities' >&2
    cat "$initial_test_log" >&2
    exit 21
fi

mapfile -t runtime_dependency_capabilities < "$derived_capabilities"
if [[ ${#runtime_dependency_capabilities[@]} -gt 0 ]]; then
    printf 'Installing %d RPM-derived runtime capabilities:\n' \
        "${#runtime_dependency_capabilities[@]}"
    printf '  %s\n' "${runtime_dependency_capabilities[@]}"
    microdnf --setopt=install_weak_deps=0 -y install \
        "${runtime_dependency_capabilities[@]}"
fi

final_test_log="$runtime_transaction_dir/final-test.log"
remaining_capabilities="$runtime_transaction_dir/remaining-capabilities.txt"
set +e
rpm -Uvh --test "${runtime_rpms[@]}" > "$final_test_log" 2>&1
final_test_status=$?
set -e
extract_unmet_capabilities "$final_test_log" "$remaining_capabilities"
if [[ $final_test_status -ne 0 ]]; then
    if [[ -s "$remaining_capabilities" ]]; then
        echo 'runtime RPM dependency closure is incomplete after capability installation:' >&2
        cat "$remaining_capabilities" >&2
    else
        echo 'runtime RPM transaction test failed after capability installation without unmet capabilities' >&2
        cat "$final_test_log" >&2
    fi
    exit 24
fi
if [[ -s "$remaining_capabilities" ]]; then
    echo 'final runtime RPM transaction test succeeded but emitted unmet capabilities' >&2
    cat "$remaining_capabilities" >&2
    exit 25
fi

rpm -Uvh "${runtime_rpms[@]}"
runtime_evr_failures=()
for package in freerdp-devel libwinpr-devel freerdp-libs libwinpr; do
    if package_evr=$(rpm -q --qf '%{EPOCHNUM}|%{VERSION}|%{RELEASE}' "$package"); then
        :
    else
        query_status=$?
        runtime_evr_failures+=("$package query-status=$query_status")
        continue
    fi
    if [[ "$package_evr" != '2|2.11.7|12.el9' ]]; then
        runtime_evr_failures+=("$package expected=2|2.11.7|12.el9 got=$package_evr")
    fi
done
if [[ ${#runtime_evr_failures[@]} -ne 0 ]]; then
    printf 'installed runtime package EVR mismatches count=%s\n' "${#runtime_evr_failures[@]}" >&2
    printf '%s\n' "${runtime_evr_failures[@]}" | sort >&2
    exit 29
fi

buildrequires_file="$runtime_transaction_dir/buildrequires.txt"
rpmspec -q --buildrequires /workspace/containers/rpm/guacamole-server.spec | \
    sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u > "$buildrequires_file"
mapfile -t build_requirements < "$buildrequires_file"
if [[ ${#build_requirements[@]} -eq 0 ]]; then
    echo 'RPM spec produced no BuildRequires capabilities' >&2
    exit 26
fi
printf 'Installing %d RPM-derived spec BuildRequires:\n' "${#build_requirements[@]}"
printf '  %s\n' "${build_requirements[@]}"
microdnf --setopt=install_weak_deps=0 -y install "${build_requirements[@]}"

# RPM 4.16.1.3's --whatprovides accepts a capability name, but does not
# evaluate a complete versioned dependency expression. microdnf above is the
# authoritative version-aware solver. This supplemental check therefore splits
# the rpmspec rendering and queries only the capability name. Exact EVR checks
# are made only for the two identities this build pins independently.
requirement_pattern='^([^[:space:]]+)([[:space:]]+(=|>=|<=|>|<)[[:space:]]+([^[:space:]]+))?$'
build_requirement_failures=()
for requirement in "${build_requirements[@]}"; do
    if [[ ! "$requirement" =~ $requirement_pattern ]]; then
        printf 'Supplemental BuildRequires check skipped for solver-accepted expression: %s\n' \
            "$requirement"
        continue
    fi
    requirement_name=${BASH_REMATCH[1]}
    requirement_operator=${BASH_REMATCH[3]}
    requirement_evr=${BASH_REMATCH[4]}
    if ! rpm -q --whatprovides "$requirement_name" >/dev/null; then
        build_requirement_failures+=("$requirement: not-provided")
        continue
    fi
    case "$requirement_name:$requirement_operator" in
        freerdp-devel:=|libwinpr-devel:=)
            installed_evr=$(rpm -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' \
                "$requirement_name")
            if [[ "$installed_evr" != "$requirement_evr" ]]; then
                build_requirement_failures+=("$requirement: installed=$installed_evr")
            fi
            ;;
        *)
            if [[ -n "$requirement_operator" ]]; then
                printf 'Version satisfaction delegated to successful microdnf transaction: %s\n' \
                    "$requirement"
            fi
            ;;
    esac
done
if [[ ${#build_requirement_failures[@]} -ne 0 ]]; then
    printf 'BuildRequires verification failures count=%s\n' "${#build_requirement_failures[@]}" >&2
    printf '%s\n' "${build_requirement_failures[@]}" | sort >&2
    exit 27
fi
runtime_evr_failures=()
for package in freerdp-devel libwinpr-devel freerdp-libs libwinpr; do
    if package_evr=$(rpm -q --qf '%{EPOCHNUM}|%{VERSION}|%{RELEASE}' "$package"); then
        :
    else
        query_status=$?
        runtime_evr_failures+=("$package query-status=$query_status")
        continue
    fi
    if [[ "$package_evr" != '2|2.11.7|12.el9' ]]; then
        runtime_evr_failures+=("$package expected=2|2.11.7|12.el9 got=$package_evr")
    fi
done
if [[ ${#runtime_evr_failures[@]} -ne 0 ]]; then
    printf 'post-BuildRequires runtime EVR mismatches count=%s\n' "${#runtime_evr_failures[@]}" >&2
    printf '%s\n' "${runtime_evr_failures[@]}" | sort >&2
    exit 31
fi

install -d /build/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
install -m 0644 /out/source/guacamole-server-1.6.0.tar.gz /build/SOURCES/
install -m 0644 /workspace/containers/patches/guacamole-server-2e2a33621d673345e7b9d22c9388be80c6d77598-wol-sockaddr.patch /build/SOURCES/
install -m 0644 /workspace/containers/rpm/guacamole-server.spec /build/SPECS/

set +e
rpmbuild -bb --define '_topdir /build' /build/SPECS/guacamole-server.spec > /out/rpmbuild.log 2>&1
status=$?
set -e
cat /out/rpmbuild.log
if [[ $status -ne 0 ]]; then
    echo "rpmbuild failed: status=$status (see /out/rpmbuild.log above)" >&2
    exit 32
fi

install -m 0644 "/build/RPMS/${rpm_arch}/guacamole-server-1.6.0-1.el9.${rpm_arch}.rpm" /out/
gcc -O2 -fPIE -pie -fstack-protector-strong -Wl,-z,relro,-z,now \
    -o /out/elf-load-probe /workspace/containers/validate/elf-load-probe.c -ldl
