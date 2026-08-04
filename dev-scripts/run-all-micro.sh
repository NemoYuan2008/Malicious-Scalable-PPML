#!/usr/bin/env bash

set -u
set -o pipefail

MALICIOUS_REPO="${HOME}/Malicious-Scalable-PPML"
MP_SPDZ_REPO="${HOME}/mp-spdz-experiments"
THROTTLE_SCRIPT="${MP_SPDZ_REPO}/dev-scripts/throttle.sh"
RESULT_FILE="${HOME}/micro-results.txt"

PROGRAMS=(4-micro-mult 4-micro-multtrunc 4-micro-dot 4-micro-relu)
NETWORKS=(lan wan)
PROTOCOLS=(atlas atlas-gsz atlas-bgin sy-shamir shamir)
PARTY_COUNTS=(3 5 7 9 11 13 15)

batch_failed=0
experiments_attempted=0
experiments_succeeded=0
experiments_failed=0
experiments_skipped=0

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

marker() {
    printf 'MICRO_EVENT timestamp=%s %s\n' "$(timestamp)" "$*"
}

protocol_repository() {
    case "$1" in
        atlas|atlas-gsz|atlas-bgin)
            printf '%s\n' "$MALICIOUS_REPO"
            ;;
        sy-shamir|shamir)
            printf '%s\n' "$MP_SPDZ_REPO"
            ;;
        *)
            return 1
            ;;
    esac
}

repository_name() {
    case "$1" in
        "$MALICIOUS_REPO")
            printf '%s\n' 'Malicious-Scalable-PPML'
            ;;
        "$MP_SPDZ_REPO")
            printf '%s\n' 'mp-spdz-experiments'
            ;;
        *)
            return 1
            ;;
    esac
}

cleanup() {
    local batch_status=$?
    local reset_status
    local final_status

    trap - EXIT
    trap '' HUP INT TERM

    marker "event=throttle_reset_begin"
    if [[ -x "$THROTTLE_SCRIPT" ]]; then
        "$THROTTLE_SCRIPT" reset
        reset_status=$?
    else
        printf 'ERROR: cannot reset throttling; executable is unavailable: %s\n' \
            "$THROTTLE_SCRIPT" >&2
        reset_status=127
    fi
    marker "event=throttle_reset_end exit_code=${reset_status}"

    final_status=$batch_status
    if (( final_status == 0 && reset_status != 0 )); then
        final_status=1
    fi

    marker "event=batch_end exit_code=${final_status} experiments_expected=280 experiments_attempted=${experiments_attempted} experiments_succeeded=${experiments_succeeded} experiments_failed=${experiments_failed} experiments_skipped=${experiments_skipped}"
    exit "$final_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! : > "$RESULT_FILE"; then
    printf 'ERROR: cannot create or truncate %s\n' "$RESULT_FILE" >&2
    exit 1
fi
exec > >(tee -a "$RESULT_FILE") 2>&1

marker "event=batch_begin programs=4 protocols=5 networks=2 party_configurations=7 compilations_expected=8 experiments_expected=280"

required_directories=(
    "$MALICIOUS_REPO"
    "$MP_SPDZ_REPO"
)
required_executables=(
    "$MALICIOUS_REPO/compile.py"
    "$MALICIOUS_REPO/Scripts/atlas.sh"
    "$MALICIOUS_REPO/Scripts/atlas-gsz.sh"
    "$MALICIOUS_REPO/Scripts/atlas-bgin.sh"
    "$MALICIOUS_REPO/atlas-party.x"
    "$MALICIOUS_REPO/atlas-gsz-party.x"
    "$MALICIOUS_REPO/atlas-bgin-party.x"
    "$MP_SPDZ_REPO/compile.py"
    "$MP_SPDZ_REPO/Scripts/sy-shamir.sh"
    "$MP_SPDZ_REPO/Scripts/shamir.sh"
    "$MP_SPDZ_REPO/sy-shamir-party.x"
    "$MP_SPDZ_REPO/shamir-party.x"
    "$THROTTLE_SCRIPT"
)

preflight_failed=0
for directory in "${required_directories[@]}"; do
    if [[ ! -d "$directory" ]]; then
        printf 'ERROR: required repository directory is missing: %s\n' \
            "$directory" >&2
        preflight_failed=1
    fi
done

for executable in "${required_executables[@]}"; do
    if [[ ! -x "$executable" ]]; then
        printf 'ERROR: required executable is missing or not executable: %s\n' \
            "$executable" >&2
        preflight_failed=1
    fi
done

for repository in "${required_directories[@]}"; do
    for program in "${PROGRAMS[@]}"; do
        source_file="${repository}/Programs/Source/${program}.py"
        if [[ ! -f "$source_file" ]]; then
            printf 'ERROR: required program source is missing: %s\n' \
                "$source_file" >&2
            preflight_failed=1
        fi
    done
done

if (( preflight_failed != 0 )); then
    marker "event=preflight_end exit_code=1"
    exit 1
fi
marker "event=preflight_end exit_code=0"

for program in "${PROGRAMS[@]}"; do
    program_failed=0
    malicious_compile_ok=0
    mp_spdz_compile_ok=0

    marker "event=program_begin program=${program}"

    for repository in "${required_directories[@]}"; do
        repo_name=$(repository_name "$repository")
        marker "event=compile_begin program=${program} repository=${repo_name} command=./compile.py_${program}_--budget_1000000"
        (
            cd "$repository" &&
                ./compile.py "$program" --budget 1000000
        )
        compile_status=$?
        marker "event=compile_end program=${program} repository=${repo_name} exit_code=${compile_status}"

        if (( compile_status == 0 )); then
            case "$repository" in
                "$MALICIOUS_REPO") malicious_compile_ok=1 ;;
                "$MP_SPDZ_REPO") mp_spdz_compile_ok=1 ;;
            esac
        else
            batch_failed=1
            program_failed=1
        fi
    done

    for network in "${NETWORKS[@]}"; do
        network_failed=0
        marker "event=network_begin program=${program} network=${network}"

        "$THROTTLE_SCRIPT" "$network"
        throttle_status=$?
        marker "event=network_configured program=${program} network=${network} exit_code=${throttle_status}"

        if (( throttle_status != 0 )); then
            batch_failed=1
            program_failed=1
            experiments_skipped=$((experiments_skipped + 35))
            marker "event=network_end program=${program} network=${network} exit_code=${throttle_status} outcome=skipped_throttle_failed experiments_skipped=35"
            continue
        fi

        for protocol in "${PROTOCOLS[@]}"; do
            repository=$(protocol_repository "$protocol")
            repo_name=$(repository_name "$repository")
            protocol_failed=0
            compile_ok=0

            case "$repository" in
                "$MALICIOUS_REPO") compile_ok=$malicious_compile_ok ;;
                "$MP_SPDZ_REPO") compile_ok=$mp_spdz_compile_ok ;;
            esac

            marker "event=protocol_begin program=${program} network=${network} protocol=${protocol} repository=${repo_name}"

            if (( compile_ok == 0 )); then
                network_failed=1
                experiments_skipped=$((experiments_skipped + 7))
                marker "event=protocol_end program=${program} network=${network} protocol=${protocol} repository=${repo_name} exit_code=1 outcome=skipped_compile_failed experiments_skipped=7"
                continue
            fi

            for parties in "${PARTY_COUNTS[@]}"; do
                marker "event=experiment_begin program=${program} network=${network} protocol=${protocol} repository=${repo_name} parties=${parties} command=./Scripts/${protocol}.sh_-N_${parties}_${program}"
                experiments_attempted=$((experiments_attempted + 1))

                (
                    cd "$repository" &&
                        "./Scripts/${protocol}.sh" -N "$parties" "$program"
                )
                experiment_status=$?

                if (( experiment_status == 0 )); then
                    experiments_succeeded=$((experiments_succeeded + 1))
                    outcome=success
                else
                    batch_failed=1
                    program_failed=1
                    network_failed=1
                    protocol_failed=1
                    experiments_failed=$((experiments_failed + 1))
                    outcome=failed
                fi

                marker "event=experiment_end program=${program} network=${network} protocol=${protocol} repository=${repo_name} parties=${parties} exit_code=${experiment_status} outcome=${outcome}"
            done

            marker "event=protocol_end program=${program} network=${network} protocol=${protocol} repository=${repo_name} exit_code=${protocol_failed} outcome=completed"
        done

        marker "event=network_end program=${program} network=${network} exit_code=${network_failed} outcome=completed"
    done

    marker "event=program_end program=${program} exit_code=${program_failed} outcome=completed"
done

exit "$batch_failed"
