#!/usr/bin/env bash

# Run from the Linux repository root. Existing results are replaced.
# Only launcher output is collected; individual party logs remain in logs/.
set -u
set -o pipefail

if [[ $(uname -s) != Linux ]]; then
    printf 'ERROR: this runner requires Linux.\n' >&2
    exit 1
fi

# The micro/all entry points select a suite here so logging and cleanup stay
# identical. With no argument this remains the original NN-only runner.
SUITE=${1:-nn}
case "$SUITE" in
    nn)
        PROGRAMS=(1-net-a 1-net-b 1-net-c 2-train-c)
        RESULT_FILE=./bgin-gsz-result.txt
        ;;
    micro)
        PROGRAMS=(4-micro-mult 4-micro-multtrunc 4-micro-dot 4-micro-relu)
        RESULT_FILE=./bgin-gsz-micro-result.txt
        ;;
    all)
        PROGRAMS=(1-net-a 1-net-b 1-net-c 2-train-c
            4-micro-mult 4-micro-multtrunc 4-micro-dot 4-micro-relu)
        RESULT_FILE=./bgin-gsz-all-result.txt
        ;;
    *)
        printf 'Usage: %s [nn|micro|all]\n' "$0" >&2
        exit 1
        ;;
esac
NETWORKS=(lan wan)
PROTOCOLS=(atlas-gsz atlas-bgin)
PARTY_COUNTS=(3 5 7 9 11 13 15)
RUNS_PER_NETWORK=$((${#PROTOCOLS[@]} * ${#PARTY_COUNTS[@]}))
RUNS_PER_PROGRAM=$((${#NETWORKS[@]} * RUNS_PER_NETWORK))
EXPECTED=$((${#PROGRAMS[@]} * RUNS_PER_PROGRAM))
THROTTLE_SCRIPT=./dev-scripts/throttle.sh

marker() {
    printf 'BGIN_GSZ_EVENT timestamp=%s %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

batch_failed=0
attempted=0
succeeded=0
failed=0
skipped=0
throttle_attempted=0

cleanup() {
    local final_status=$?
    local reset_status
    trap - EXIT
    trap '' HUP INT TERM

    if (( throttle_attempted )); then
        marker 'event=throttle_reset_begin'
        bash "$THROTTLE_SCRIPT" reset
        reset_status=$?
        marker "event=throttle_reset_end exit_code=${reset_status}"
        if (( reset_status != 0 && final_status == 0 )); then
            final_status=1
        fi
    fi

    marker "event=batch_end suite=${SUITE} exit_code=${final_status} experiments_expected=${EXPECTED} experiments_attempted=${attempted} experiments_succeeded=${succeeded} experiments_failed=${failed} experiments_skipped=${skipped}"
    exit "$final_status"
}

run_batch() {
    local program network protocol parties status outcome context
    local program_failed network_failed
    local preflight_failed=0
    local required
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    marker "event=batch_begin suite=${SUITE} programs=${#PROGRAMS[@]} networks=${#NETWORKS[@]} protocols=${#PROTOCOLS[@]} party_configurations=${#PARTY_COUNTS[@]} compilations_expected=${#PROGRAMS[@]} experiments_expected=${EXPECTED}"
    for required in ./compile.py \
        ./Scripts/atlas-gsz.sh ./Scripts/atlas-bgin.sh \
        ./atlas-gsz-party.x ./atlas-bgin-party.x; do
        if [[ ! -x "$required" ]]; then
            printf 'ERROR: missing or non-executable file: %s\n' "$required" >&2
            preflight_failed=1
        fi
    done
    for required in "$THROTTLE_SCRIPT" ./Scripts/run-common.sh \
        "${PROGRAMS[@]/#/./Programs/Source/}"; do
        # Program sources have a .py suffix; the two shell scripts do not.
        case "$required" in
            ./Programs/Source/*) required=${required}.py ;;
        esac
        if [[ ! -r "$required" ]]; then
            printf 'ERROR: missing or unreadable file: %s\n' "$required" >&2
            preflight_failed=1
        fi
    done
    marker "event=preflight_end exit_code=${preflight_failed}"
    if (( preflight_failed )); then
        skipped=$EXPECTED
        exit 1
    fi

    for program in "${PROGRAMS[@]}"; do
        program_failed=0
        marker "event=program_begin program=${program}"
        marker "event=compile_begin program=${program} budget=1000000"
        ./compile.py "$program" --budget 1000000
        status=$?
        marker "event=compile_end program=${program} exit_code=${status}"
        if (( status != 0 )); then
            batch_failed=1
            skipped=$((skipped + RUNS_PER_PROGRAM))
            marker "event=program_end program=${program} exit_code=${status} outcome=skipped_compile_failed experiments_skipped=${RUNS_PER_PROGRAM}"
            continue
        fi

        for network in "${NETWORKS[@]}"; do
            network_failed=0
            marker "event=network_begin program=${program} network=${network}"
            throttle_attempted=1
            bash "$THROTTLE_SCRIPT" "$network"
            status=$?
            marker "event=network_configured program=${program} network=${network} exit_code=${status}"
            if (( status != 0 )); then
                batch_failed=1
                program_failed=1
                skipped=$((skipped + RUNS_PER_NETWORK))
                marker "event=network_end program=${program} network=${network} exit_code=${status} outcome=skipped_throttle_failed experiments_skipped=${RUNS_PER_NETWORK}"
                continue
            fi

            for protocol in "${PROTOCOLS[@]}"; do
                for parties in "${PARTY_COUNTS[@]}"; do
                    context="program=${program} network=${network} protocol=${protocol} parties=${parties}"
                    marker "event=experiment_begin ${context}"
                    attempted=$((attempted + 1))
                    "./Scripts/${protocol}.sh" -N "$parties" "$program"
                    status=$?
                    if (( status == 0 )); then
                        succeeded=$((succeeded + 1))
                        outcome=success
                    else
                        failed=$((failed + 1))
                        batch_failed=1
                        program_failed=1
                        network_failed=1
                        outcome=failed
                    fi
                    marker "event=experiment_end ${context} exit_code=${status} outcome=${outcome}"
                done
            done
            marker "event=network_end program=${program} network=${network} exit_code=${network_failed} outcome=completed"
        done
        marker "event=program_end program=${program} exit_code=${program_failed} outcome=completed"
    done
    exit "$batch_failed"
}

if ! : > "$RESULT_FILE"; then
    printf 'ERROR: cannot create result file: %s\n' "$RESULT_FILE" >&2
    exit 1
fi

# Keep cleanup output in the same stream and wait for tee to finish writing.
# pipefail also makes a log-writing failure produce a nonzero batch exit.
(run_batch) 2>&1 | tee -a "$RESULT_FILE"
exit $?
