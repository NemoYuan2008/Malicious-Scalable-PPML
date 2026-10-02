#!/usr/bin/env bash

# Invoke from any directory on Linux. Both repositories must be under $HOME.
# Runs our 224 experiments, then Helix's 42; replaces the combined result file.
# Child runners own compilation, individual logs, and throttle cleanup.
set -u
set -o pipefail
set +m  # A background child's PID must remain the PID used by setsid.

if [[ $(uname -s) != Linux ]]; then
    printf 'ERROR: this runner requires Linux.\n' >&2
    exit 1
fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf 'ERROR: Bash 4.3 or newer is required.\n' >&2
    exit 1
fi

OUR_REPO="${HOME}/Malicious-Scalable-PPML"
HELIX_REPO="${HOME}/helix"
RESULT_FILE="$OUR_REPO/bgin-gsz-helix-all-result.txt"
preflight_failed=0
for required in bash setsid env tee date sleep; do
    if ! command -v "$required" >/dev/null 2>&1; then
        printf 'ERROR: required command unavailable: %s\n' "$required" >&2
        preflight_failed=1
    fi
done
for required in "$OUR_REPO" "$HELIX_REPO"; do
    if [[ ! -d "$required" ]]; then
        printf 'ERROR: repository missing: %s\n' "$required" >&2
        preflight_failed=1
    fi
done
for required in "$OUR_REPO/dev-scripts/run_bgin_gsz_all.sh" \
    "$OUR_REPO/dev-scripts/run_bgin_gsz.sh" \
    "$OUR_REPO/dev-scripts/throttle.sh" "$HELIX_REPO/run_helix.sh"; do
    if [[ ! -r "$required" ]]; then
        printf 'ERROR: runner or throttle script unreadable: %s\n' "$required" >&2
        preflight_failed=1
    fi
done
if (( preflight_failed )); then exit 1; fi
# Bash backgrounds commands with SIGINT ignored. GNU env restores it before
# starting Bash so the isolated runner can install its own interruption traps.
if ! env --default-signal=INT,QUIT true; then
    printf 'ERROR: GNU env with --default-signal support is required.\n' >&2
    exit 1
fi
if ! : > "$RESULT_FILE"; then
    printf 'ERROR: cannot create result file: %s\n' "$RESULT_FILE" >&2
    exit 1
fi

marker() {
    printf 'COMBINED_EVENT timestamp=%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

active_pid=
interrupted=0
interrupt_signal=
batch_failed=0
repositories_attempted=0
repositories_succeeded=0
repositories_failed=0

forward_signal() {
    local signal=$1
    [[ -n "$active_pid" ]] || return 0
    # A signal can arrive immediately after launch, before setsid creates the
    # group. Wait for that transition rather than signaling only its leader.
    while kill -0 "$active_pid" 2>/dev/null; do
        if kill -s "$signal" -- "-$active_pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
}

interrupt_batch() {
    interrupt_signal=$1
    interrupted=$2
    trap '' HUP INT TERM
    marker "event=interrupted signal=${interrupt_signal} exit_code=${interrupted}"
    forward_signal "$interrupt_signal"
}

finish() {
    local status=$? log_status outcome
    trap - EXIT
    trap '' HUP INT TERM
    if (( interrupted )); then
        status=$interrupted
        outcome=interrupted
    elif (( status != 0 )); then
        outcome=failed
    else
        outcome=success
    fi
    marker "event=batch_end exit_code=${status} outcome=${outcome} experiments_expected=266 repositories_attempted=${repositories_attempted} repositories_succeeded=${repositories_succeeded} repositories_failed=${repositories_failed}"
    # Close the writer and wait for tee, including its final disk write.
    exec 1>&3 2>&4 3>&- 4>&-
    wait "$logger_pid"
    log_status=$?
    if (( log_status != 0 )); then
        printf 'ERROR: combined log writer failed (exit %s).\n' "$log_status" >&2
        if (( status == 0 )); then status=1; fi
    fi
    exit "$status"
}

# Make tee ignore terminal interruption so it can retain the active runner's
# cleanup and summary output after Ctrl-C.
exec 3>&1 4>&2
exec > >(trap '' HUP INT TERM; exec tee -a "$RESULT_FILE") 2>&1
logger_pid=$!
trap finish EXIT
trap 'interrupt_batch HUP 129' HUP
trap 'interrupt_batch INT 130' INT
trap 'interrupt_batch TERM 143' TERM

run_repository() {
    local name=$1 directory=$2 runner=$3 expected=$4 status outcome
    if (( interrupted )); then return; fi
    marker "event=repository_begin repository=${name} experiments_expected=${expected}"
    repositories_attempted=$((repositories_attempted + 1))
    setsid env --default-signal=INT,QUIT bash -c \
        'cd -- "$1" || exit 1; exec bash "$2"' \
        combined-runner "$directory" "$runner" 3>&- 4>&- &
    active_pid=$!
    # Cover an interruption between starting the child and recording its PID.
    if (( interrupted )); then forward_signal "$interrupt_signal"; fi
    wait "$active_pid"
    status=$?
    if (( interrupted )); then
        # A trapped signal interrupts wait; wait again for child cleanup.
        wait "$active_pid" 2>/dev/null || :
        status=$interrupted
        outcome=interrupted
    elif (( status == 0 )); then
        outcome=success
    else
        outcome=failed
    fi
    active_pid=
    if (( status == 0 )); then
        repositories_succeeded=$((repositories_succeeded + 1))
    else
        repositories_failed=$((repositories_failed + 1))
        batch_failed=1
    fi
    marker "event=repository_end repository=${name} experiments_expected=${expected} exit_code=${status} outcome=${outcome}"
}

marker 'event=batch_begin repositories=2 experiments_expected=266'
run_repository Malicious-Scalable-PPML "$OUR_REPO" ./dev-scripts/run_bgin_gsz_all.sh 224
run_repository helix "$HELIX_REPO" ./run_helix.sh 42
exit "$batch_failed"
