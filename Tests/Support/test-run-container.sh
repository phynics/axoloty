#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

# Each scenario below sets BUILD_LOCK explicitly (or relies on run.sh's
# default of 1); an inherited BUILD_LOCK from the caller's environment (e.g.
# `make ci ... BUILD_LOCK=0`, which the Makefile exports) would silently
# override that and break the lock-behavior assertions.
unset BUILD_LOCK BUILD_LOCK_FORCE_DIRECTORY

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=expected-failure.sh
source "$ROOT_DIR/Tests/Support/expected-failure.sh"
TEMP_DIR=$(mktemp -d)
socket_server=""
export AXOLOTY_ESP_IDF_CCACHE_DIR="$TEMP_DIR/esp-idf-ccache"

cleanup() {
    if [ -n "$socket_server" ]; then
        kill "$socket_server" 2>/dev/null || true
        wait_bounded "$socket_server" cleanup-socket-server 5 || true
    fi
    if [ "${KEEP_TEMP:-0}" != "1" ]; then
        rm -rf "$TEMP_DIR"
    else
        printf 'kept temp: %s\n' "$TEMP_DIR" >&2
    fi
}

trap cleanup EXIT

common_git_dir=$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if [ -n "$common_git_dir" ]; then
    expected_repository_name=$(basename "${common_git_dir%/.git}")
else
    expected_repository_name=$(basename "$ROOT_DIR")
fi
expected_worktree_name=$(basename "$ROOT_DIR")
expected_worktree_name=$(printf '%s' "$expected_worktree_name" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-24)

build_dir="$TEMP_DIR/build"
lock_file="${build_dir}.lock"
lock_owner="${build_dir}.lock.owner"

wait_for_path() {
    path="$1"
    deadline=$(( $(date +%s) + "$2" ))
    while [ ! -e "$path" ] && [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 0.1
    done
    [ -e "$path" ]
}

wait_bounded() {
    pid="$1"
    label="$2"
    timeout_seconds="$3"
    deadline=$(( $(date +%s) + timeout_seconds ))
    while kill -0 "$pid" 2>/dev/null; do
        process_state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
        case "$process_state" in
            Z*) break ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "wait timeout: $label pid=$pid after ${timeout_seconds}s" >&2
            kill -TERM "$pid" 2>/dev/null || true
            sleep 0.1
            kill -KILL "$pid" 2>/dev/null || true
            process_state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
            case "$process_state" in
                Z*) break ;;
                *)
                    echo "wait failure: $label pid=$pid remained alive after SIGKILL" >&2
                    return 1
                    ;;
            esac
        fi
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        process_state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
        case "$process_state" in
            Z*) wait "$pid" 2>/dev/null || true ;;
            *)
                echo "wait failure: $label pid=$pid could not be reaped safely" >&2
                return 1
                ;;
        esac
    else
        wait "$pid" 2>/dev/null || true
    fi
}

# Resolve locking must recover stale legacy directories and serialize peers.
resolve_cache="$TEMP_DIR/resolve-cache"
resolve_bin="$TEMP_DIR/resolve-bin"
resolve_calls="$TEMP_DIR/resolve-calls"
resolve_overlap="$TEMP_DIR/resolve-overlap"
mkdir -p "$resolve_cache/.resolve.lock" "$resolve_bin"
touch -d '2 hours ago' "$resolve_cache/.resolve.lock"
cat > "$resolve_bin/swift" <<'SH'
#!/bin/sh
set -eu
for argument do
    cache_dir=$argument
done
if ! mkdir "$cache_dir/.resolve-active" 2>/dev/null; then
    : > "$AXOLOTY_RESOLVE_OVERLAP"
    exit 1
fi
trap 'rmdir "$cache_dir/.resolve-active"' EXIT INT TERM
printf 'resolve\n' >> "$AXOLOTY_RESOLVE_CALLS"
printf '%s\n' "$*" >> "$AXOLOTY_RESOLVE_ARGUMENTS"
sleep 0.2
SH
chmod +x "$resolve_bin/swift"
resolve_arguments="$TEMP_DIR/resolve-arguments"
AXOLOTY_RESOLVE_CACHE_DIR="$resolve_cache" AXOLOTY_RESOLVE_CALLS="$resolve_calls" \
AXOLOTY_RESOLVE_ARGUMENTS="$resolve_arguments" AXOLOTY_RESOLVE_OVERLAP="$resolve_overlap" PATH="$resolve_bin:$PATH" \
    "$ROOT_DIR/.devcontainer/resolve.sh" &
resolve_first=$!
AXOLOTY_RESOLVE_CACHE_DIR="$resolve_cache" AXOLOTY_RESOLVE_CALLS="$resolve_calls" \
AXOLOTY_RESOLVE_ARGUMENTS="$resolve_arguments" AXOLOTY_RESOLVE_OVERLAP="$resolve_overlap" PATH="$resolve_bin:$PATH" \
    "$ROOT_DIR/.devcontainer/resolve.sh" &
resolve_second=$!
wait_bounded "$resolve_first" resolve-first 5
wait_bounded "$resolve_second" resolve-second 5
[[ "$(wc -l < "$resolve_calls")" -eq 2 ]]
[[ ! -e "$resolve_overlap" ]]
[[ ! -d "$resolve_cache/.resolve.lock" ]]
AXOLOTY_RESOLVE_CACHE_DIR="$resolve_cache" AXOLOTY_RESOLVE_CALLS="$resolve_calls" \
AXOLOTY_RESOLVE_ARGUMENTS="$resolve_arguments" AXOLOTY_RESOLVE_OVERLAP="$resolve_overlap" \
AXOLOTY_RESOLVE_PACKAGE_PATH="Packages/AxolotyStaticRuntime" PATH="$resolve_bin:$PATH" \
    "$ROOT_DIR/.devcontainer/resolve.sh"
grep -Fqx "package --package-path Packages/AxolotyStaticRuntime resolve --cache-path $resolve_cache" \
    "$resolve_arguments"

# The lock must be released after a direct devcontainer command exits.
AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" "$ROOT_DIR/.devcontainer/run.sh" true
[[ ! -e "$lock_owner" ]]

# Nested execution inside an existing devcontainer keeps tooling isolated under
# the selected build directory rather than falling back to the workspace path.
direct_tooling_capture="$TEMP_DIR/direct-tooling-build-dir"
AXOLOTY_TOOLING_CAPTURE="$direct_tooling_capture" AXOLOTY_DEVCONTAINER=1 \
    BUILD_DIR="$build_dir" "$ROOT_DIR/.devcontainer/run.sh" \
    sh -c 'printf "%s\n" "$TOOLING_BUILD_DIR" > "$AXOLOTY_TOOLING_CAPTURE"'
[[ "$(cat "$direct_tooling_capture")" = "$build_dir/tooling" ]]

# A second operation waits for the owner instead of touching the shared cache.
# Synchronize on explicit markers: integer wall-clock sampling made this test
# fail whenever a sub-second wait crossed neither side of a one-second tick.
holder_ready="$TEMP_DIR/build-lock-holder.ready"
holder_release="$TEMP_DIR/build-lock-holder.release"
waiter_completed="$TEMP_DIR/build-lock-waiter.completed"
waiter_status="$TEMP_DIR/build-lock-waiter.status"
( exec 8>"$lock_file"; flock 8; : > "$holder_ready"; while [ ! -e "$holder_release" ]; do sleep 0.05; done ) &
holder=$!
wait_for_path "$holder_ready" 5
(
    set +e
    AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" "$ROOT_DIR/.devcontainer/run.sh" true
    waiter_exit=$?
    printf '%s\n' "$waiter_exit" > "$waiter_status"
    if [ "$waiter_exit" -eq 0 ]; then
        : > "$waiter_completed"
    fi
    exit "$waiter_exit"
) &
waiter=$!
sleep 0.2
if [ -e "$waiter_completed" ] || ! kill -0 "$waiter" 2>/dev/null; then
    echo "build-lock waiter completed before the owner released the lock" >&2
    exit 1
fi
: > "$holder_release"
wait_bounded "$holder" build-lock-holder 5
wait_bounded "$waiter" build-lock-waiter 5
[[ -e "$waiter_status" ]]
[[ "$(cat "$waiter_status")" -eq 0 ]]
[[ -e "$waiter_completed" ]]
[[ ! -e "$lock_owner" ]]

# Signal forwarding must reach an executable descendant, not only the shell
# that run.sh directly started.
tree_child="$TEMP_DIR/tree-child.sh"
tree_parent="$TEMP_DIR/tree-parent.sh"
tree_child_pid="$TEMP_DIR/tree-child.pid"
tree_exited="$TEMP_DIR/tree-child.exited"
cat > "$tree_child" <<'SH'
#!/bin/sh
pid_file=$1
exited_marker=$2
printf '%s' "$$" > "$pid_file"
trap 'printf exited > "$exited_marker"; exit 0' TERM INT
while :; do sleep 1; done
SH
cat > "$tree_parent" <<'SH'
#!/bin/sh
child_script=$1
child_pid_file=$2
exited_marker=$3
wait_bounded() {
    pid=$1
    deadline=$(( $(date +%s) + 5 ))
    while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "tree-parent wait timeout: pid=$pid" >&2
        kill -KILL "$pid" 2>/dev/null || true
    fi
    if kill -0 "$pid" 2>/dev/null; then
        state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
        case "$state" in
            Z*) wait "$pid" 2>/dev/null || true ;;
            *) echo "tree-parent could not reap pid=$pid safely" >&2; return 1 ;;
        esac
    else
        wait "$pid" 2>/dev/null || true
    fi
}
"$child_script" "$child_pid_file" "$exited_marker" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null || true; wait_bounded "$child"; exit 143' TERM INT
wait_bounded "$child"
SH
chmod +x "$tree_child" "$tree_parent"

    AXOLOTY_DEVCONTAINER=1 BUILD_LOCK=0 CONTAINER_TERM_GRACE_SECONDS=1 \
    "$ROOT_DIR/.devcontainer/run.sh" "$tree_parent" "$tree_child" "$tree_child_pid" "$tree_exited" \
    >"$TEMP_DIR/direct-signal.log" 2>&1 &
direct_runner=$!
wait_for_path "$tree_child_pid" 5
kill -TERM "$direct_runner" 2>/dev/null || true
set +e
    wait_bounded "$direct_runner" direct-runner 5 || true
set -e
if [ ! -e "$tree_exited" ]; then
    cat "$TEMP_DIR/direct-signal.log" >&2
    if [ -s "$tree_child_pid" ]; then
        child_pid=$(cat "$tree_child_pid")
        child_state=$(ps -o stat= -p "$child_pid" 2>/dev/null | tr -d ' ' || true)
        echo "direct signal marker missing: child pid=$child_pid state=${child_state:-absent}" >&2
    else
        echo "direct signal marker missing: child pid was not recorded" >&2
    fi
fi
[ -e "$tree_exited" ]
child_pid=$(cat "$tree_child_pid")
if kill -0 "$child_pid" 2>/dev/null; then
    echo "direct run.sh left an executable descendant" >&2
    exit 1
fi

# Repeat the same assertion through the fake container runtime boundary.
rm -f "$tree_child_pid" "$tree_exited"

# The canonical CI plan invokes this harness from inside the development
# container, where run.sh exports this marker for its child command. Clear the
# inherited marker before exercising the host-side fake-runtime paths below;
# each direct-mode scenario above opts in explicitly.
unset AXOLOTY_DEVCONTAINER

# The flock path must honor immediate and finite BUILD_LOCK_TIMEOUT values.
flock_timeout_output="$TEMP_DIR/flock-timeout.stderr"
( exec 8>"$lock_file"; flock 8; sleep 3 ) &
holder=$!
sleep 0.1
set +e
BUILD_LOCK_TIMEOUT=0 AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>"$flock_timeout_output"
status=$?
set -e
[[ "$status" -eq 75 ]]
grep -Fxq "Waiting up to 0s for build lock: $lock_file" "$flock_timeout_output"
grep -Fxq "Timed out waiting for build lock: $lock_file" "$flock_timeout_output"

set +e
BUILD_LOCK_TIMEOUT=1 AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>"$flock_timeout_output"
status=$?
set -e
[[ "$status" -eq 75 ]]
grep -Fxq "Waiting up to 1s for build lock: $lock_file" "$flock_timeout_output"
grep -Fxq "Timed out waiting for build lock: $lock_file" "$flock_timeout_output"
kill "$holder" 2>/dev/null || true
wait_bounded "$holder" flock-timeout-holder 5 || true

# The mkdir fallback cannot wait forever when flock is unavailable.
fallback_lock_dir="${build_dir}.lock.d"
mkdir "$fallback_lock_dir"
if BUILD_LOCK_FORCE_DIRECTORY=1 BUILD_LOCK_TIMEOUT=0 AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected the fallback lock timeout to fail" >&2
    exit 1
fi
rmdir "$fallback_lock_dir"

# A directory lock with no live owner can be reclaimed once its configured
# stale age is reached.
mkdir "$fallback_lock_dir"
run_labeled_command "container/stale-lock-reclaimed" env \
    BUILD_LOCK_FORCE_DIRECTORY=1 BUILD_LOCK_STALE_SECONDS=0 AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" \
    "$ROOT_DIR/.devcontainer/run.sh" true
[[ ! -e "$fallback_lock_dir" ]]

# Isolated CI runners do not share a build directory, so they must not wait
# behind an unrelated lock directory.
( exec 8>"$lock_file"; flock 8; sleep 2 ) &
holder=$!
AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" BUILD_LOCK=0 "$ROOT_DIR/.devcontainer/run.sh" true
kill "$holder" 2>/dev/null || true
wait_bounded "$holder" isolated-lock-holder 5 || true

# Device runs auto-select a usable non-interactive sudo wrapper. Use fakes so
# the behavior is deterministic and does not require a real device or sudo.
fake_bin="$TEMP_DIR/bin"
capture="$TEMP_DIR/runtime-args.txt"
capture_argv="$TEMP_DIR/runtime-argv.txt"
capture_env="$TEMP_DIR/runtime-env.txt"
capture_child_env="$TEMP_DIR/runtime-child-env.txt"
capture_sequence="$TEMP_DIR/runtime-sequence.txt"
capture_state="$TEMP_DIR/runtime-state.txt"
capture_inspect_count="$TEMP_DIR/runtime-inspect-count.txt"
capture_descendant="$TEMP_DIR/runtime-descendant.pid"
capture_api_pid="$TEMP_DIR/runtime-api.pid"
capture_command="$TEMP_DIR/runtime-command.txt"
capture_command_env="$TEMP_DIR/runtime-command-env.txt"
: > "$capture_sequence"
: > "$capture_state"
: > "$capture_inspect_count"
: > "$capture_argv"

mkdir -p "$fake_bin"
cat > "$fake_bin/fake-sudo" <<'SH'
#!/bin/sh
if [ "$1" = "-n" ]; then shift; fi
FAKE_RUNTIME_ROOTFUL=1 exec "$@"
SH
cat > "$fake_bin/fake-podman" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$capture"
if [ "\${FAKE_RUNTIME_ARGV_CAPTURE:-0}" = "1" ]; then
    printf '%s\n' '---' >> "$capture_argv"
    for fake_arg do
        printf '%s\n' "\$fake_arg" >> "$capture_argv"
    done
fi
record_sequence() { printf '%s\n' "\$1" >> "$capture_sequence"; }
if [ "\${FAKE_FOREIGN_INSPECT:-0}" = "1" ] && [ "\$1" = "inspect" ]; then
    record_sequence inspect-foreign
    printf '%s\n' "foreign-container-id|foreign-owner|foreign-run|foreign-worktree|foreign-process|foreign-instance"
    exit 0
fi
if [ "\${FAKE_FOREIGN_INSPECT:-0}" = "1" ] && { [ "\$1" = "stop" ] || [ "\$1" = "kill" ] || [ "\$1" = "rm" ]; }; then
    printf '%s\n' "unexpected cleanup of foreign container" >&2
    exit 99
fi
if [ "\$1" = "inspect" ]; then
    if [ "\${FAKE_INSPECT_BLOCK:-0}" = "1" ]; then
        printf '%s\n' "\$\$" > "$capture_api_pid"
        trap 'exit 143' TERM INT
        while :; do sleep 1; done
    fi
    if [ "\${FAKE_INSPECT_FAILURE_ONCE:-0}" = "1" ] && [ ! -s "$capture_inspect_count" ]; then
        printf '%s\n' 1 > "$capture_inspect_count"
        exit "\${FAKE_INSPECT_EXIT_CODE:-125}"
    fi
    if [ "\${3:-}" = "{{.State.Status}}" ]; then
        record_sequence inspect-status
        [ -f "$capture_state" ] && . "$capture_state"
        printf '%s\n' "\${FAKE_CONTAINER_STATUS:-exited}"
        exit 0
    fi
    record_sequence inspect
    [ -f "$capture_state" ] && . "$capture_state"
    printf '%s\n' "fake-container-id|\${FAKE_CONTAINER_LABELS:-}"
    exit 0
fi
if [ "\$1" = "container" ] && [ "\$2" = "exists" ]; then
    record_sequence exists
    if [ "\${FAKE_EXISTS_FAILURE:-0}" = "1" ]; then
        exit 42
    fi
    [ -f "$capture_state" ]
    exit "\$?"
fi
if [ "\$1" = "stop" ]; then
    record_sequence stop
    if [ "\${FAKE_STOP_FAIL_IF_EXITED:-0}" = "1" ]; then
        [ -f "$capture_state" ] && . "$capture_state"
        if [ "\${FAKE_CONTAINER_STATUS:-exited}" != "running" ]; then
            exit 42
        fi
    fi
    if [ "\${FAKE_STOP_IGNORES:-0}" != "1" ]; then
        printf '%s\n' 'FAKE_CONTAINER_STATUS=exited' >> "$capture_state"
    fi
    exit 0
fi
if [ "\$1" = "kill" ]; then
    record_sequence kill
    printf '%s\n' 'FAKE_CONTAINER_STATUS=exited' >> "$capture_state"
    exit 0
fi
if [ "\$1" = "rm" ]; then
    record_sequence rm
    if [ "\${FAKE_CLEANUP_BLOCK:-0}" = "1" ]; then
        trap 'exit 143' TERM INT
        while :; do sleep 1; done
    fi
    if [ "\${FAKE_RM_FAILURE:-0}" = "1" ]; then
        exit 42
    fi
    rm -f "$capture_state"
    exit 0
fi
if [ "\$1" = "system" ] && [ "\$2" = "service" ]; then
    exec python3 -c 'import socket,sys,time; p=sys.argv[1][7:]; s=socket.socket(socket.AF_UNIX); s.bind(p); s.listen(1); time.sleep(300)' "\$4"
fi
if [ "\$1" = "image" ] && [ "\$2" = "inspect" ]; then
    if [ "\${FAKE_RUNTIME_ROOTFUL:-0}" = "1" ]; then
        printf '%s\n' "\${FAKE_RUNTIME_ROOTFUL_IMAGE_ID:-rootful-image}"
    else
        printf '%s\n' rootless-image
    fi
    exit 0
fi
if [ "\$1" = "save" ]; then
    printf '%s' fake-image
    exit 0
fi
if [ "\$1" = "load" ]; then
    cat >/dev/null
    exit 0
fi
if [ "\$1" = "create" ]; then
    record_sequence create
    shift
    : > "$capture_command_env"
    fake_name=""
    fake_managed=""
    fake_run=""
    fake_worktree=""
    fake_owner=""
    fake_instance=""
    fake_cidfile=""
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            --name)
                fake_name="\$2"
                shift 2
                ;;
            --cidfile)
                fake_cidfile="\$2"
                shift 2
                ;;
            --label)
                case "\$2" in
                    io.axoloty.managed-by=*) fake_managed="\${2#*=}" ;;
                    io.axoloty.run-id=*) fake_run="\${2#*=}" ;;
                    io.axoloty.worktree=*) fake_worktree="\${2#*=}" ;;
                    io.axoloty.owner=*) fake_owner="\${2#*=}" ;;
                    io.axoloty.instance=*) fake_instance="\${2#*=}" ;;
                esac
                shift 2
                ;;
            -e|--env)
                printf '%s\n' "\$2" >> "$capture_command_env"
                shift 2
                ;;
            -v|-w|--security-opt|--user|--device|-p|--network)
                shift 2
                ;;
            --env-file)
                cp "\$2" "$capture_env"
                cat "\$2" >> "$capture_command_env"
                shift 2
                ;;
            --rm|--privileged|-i|--interactive|--tty|--userns=*)
                shift
                ;;
            axoloty-dev)
                shift
                : > "$capture_command"
                for fake_arg do
                    printf '%s\n' "\$fake_arg" >> "$capture_command"
                done
                if [ "\${FAKE_CREATE_COLLISION:-0}" = "1" ]; then
                    if [ "\${FAKE_COLLISION_MATCHING_LABELS:-0}" = "1" ]; then
                        printf "FAKE_CONTAINER_LABELS='%s'\n" "\$fake_managed|\$fake_run|\$fake_worktree|\$fake_owner|foreign-instance" > "$capture_state"
                        printf 'FAKE_CONTAINER_STATUS=running\n' >> "$capture_state"
                    fi
                    printf '%s\n' 'container name is already in use' >&2
                    exit 125
                fi
                if [ "\${FAKE_CREATE_FAILURE:-0}" = "1" ]; then
                    exit "\${FAKE_CREATE_EXIT_CODE:-126}"
                fi
                if [ -n "\$fake_cidfile" ] && [ "\${FAKE_SKIP_CIDFILE:-0}" != "1" ]; then
                    printf '%s\n' fake-container-id > "\$fake_cidfile"
                fi
                printf "FAKE_CONTAINER_LABELS='%s'\n" "\$fake_managed|\$fake_run|\$fake_worktree|\$fake_owner|\$fake_instance" > "$capture_state"
                printf 'FAKE_CONTAINER_STATUS=created\n' >> "$capture_state"
                if [ "\${FAKE_CREATE_BLOCK_AFTER_COMMIT:-0}" = "1" ]; then
                    printf '%s\n' "\$\$" > "$capture_api_pid"
                    trap 'exit 143' TERM INT
                    while :; do sleep 1; done
                fi
                if [ "\${FAKE_CREATE_COMMIT_THEN_FAIL:-0}" = "1" ]; then
                    exit "\${FAKE_CREATE_EXIT_CODE:-124}"
                fi
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done
    exit 2
fi
if [ "\$1" = "start" ]; then
    record_sequence start
    shift
    fake_start_interactive=0
    fake_start_id=""
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            --attach) shift ;;
            --interactive) fake_start_interactive=1; shift ;;
            *) fake_start_id="\$1"; shift ;;
        esac
    done
    if [ "\${FAKE_START_FAILURE:-0}" = "1" ]; then
        exit "\${FAKE_START_EXIT_CODE:-127}"
    fi
    if [ "\$fake_start_id" != "fake-container-id" ]; then
        echo "unexpected start ID: \$fake_start_id" >&2
        exit 125
    fi
    printf '%s\n' 'FAKE_CONTAINER_STATUS=running' >> "$capture_state"
    if [ "\${FAKE_RUNTIME_LEAK_DESCENDANT:-0}" = "1" ]; then
        (trap 'exit 0' TERM INT; while :; do sleep 1; done) >/dev/null 2>&1 &
        printf '%s\n' "\$!" > "$capture_descendant"
    fi
    set --
    if [ -f "$capture_command" ]; then
        while IFS= read -r fake_arg; do
            set -- "\$@" "\$fake_arg"
        done < "$capture_command"
    fi
    if [ "\$#" -eq 0 ]; then
        exit 0
    fi
    if [ -f "$capture_command_env" ]; then
        while IFS= read -r fake_assignment; do
            export "\$fake_assignment"
        done < "$capture_command_env"
    fi
    "\$@"
    fake_start_status=\$?
    if [ "\${FAKE_RUNTIME_EXIT_CODE:-0}" != "0" ]; then
        fake_start_status=\$FAKE_RUNTIME_EXIT_CODE
    fi
    printf '%s\n' 'FAKE_CONTAINER_STATUS=exited' >> "$capture_state"
    exit "\$fake_start_status"
fi
if [ "\${FAKE_RUNTIME_EXECUTE_COMMAND:-0}" = "1" ] && [ "\$1" = "run" ]; then
    shift
    fake_name=""
    fake_managed=""
    fake_run=""
    fake_worktree=""
    fake_owner=""
    fake_cidfile=""
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            -e|--env)
                export "\$2"
                shift 2
                ;;
            --name)
                fake_name="\$2"
                shift 2
                ;;
            --cidfile)
                fake_cidfile="\$2"
                shift 2
                ;;
            --label)
                case "\$2" in
                    io.axoloty.managed-by=*) fake_managed="\${2#*=}" ;;
                    io.axoloty.run-id=*) fake_run="\${2#*=}" ;;
                    io.axoloty.worktree=*) fake_worktree="\${2#*=}" ;;
                    io.axoloty.owner=*) fake_owner="\${2#*=}" ;;
                esac
                shift 2
                ;;
            --env-file)
                cp "\$2" "$capture_env"
                while IFS= read -r fake_assignment; do
                    export "\$fake_assignment"
                done < "\$2"
                shift 2
                ;;
            -v|-w|--security-opt|--user|--device|-p|--network)
                shift 2
                ;;
            --rm|--privileged|-i|--userns=*)
                shift
                ;;
            axoloty-dev)
                shift
                if [ -n "\$fake_cidfile" ] && [ "\${FAKE_SKIP_CIDFILE:-0}" != "1" ]; then
                    printf '%s\n' fake-container-id > "\$fake_cidfile"
                fi
                if [ "\${FAKE_RUNTIME_BLOCK_LAUNCH:-0}" = "1" ]; then
                    trap 'exit 143' TERM INT
                    while :; do sleep 1; done
                fi
                if [ "\${FAKE_DELAYED_OWNED_CONTAINER:-0}" = "1" ]; then
                    (
                        sleep "\${FAKE_OWNERSHIP_DELAY_SECONDS:-0.3}"
                        printf "FAKE_CONTAINER_LABELS='%s'\n" "\$fake_managed|\$fake_run|\$fake_worktree|\$fake_owner" > "$capture_state"
                        printf 'FAKE_CONTAINER_STATUS=running\n' >> "$capture_state"
                    ) &
                    sleep "\${FAKE_RUNTIME_LIFETIME_SECONDS:-1}"
                fi
                if [ "\${FAKE_DELAYED_FOREIGN_CONTAINER:-0}" = "1" ]; then
                    (
                        sleep 0.3
                        printf '%s\n' 'FAKE_CONTAINER_LABELS=foreign-owner|foreign-run|foreign-worktree|foreign-process' > "$capture_state"
                        printf 'FAKE_CONTAINER_STATUS=running\n' >> "$capture_state"
                    ) &
                    exit 125
                fi
                printf "FAKE_CONTAINER_LABELS='%s'\n" "\$fake_managed|\$fake_run|\$fake_worktree|\$fake_owner" > "$capture_state"
                printf 'FAKE_CONTAINER_STATUS=running\n' >> "$capture_state"
                if [ "\${FAKE_RUNTIME_LEAK_DESCENDANT:-0}" = "1" ]; then
                    (trap 'exit 0' TERM INT; while :; do sleep 1; done) >/dev/null 2>&1 &
                    printf '%s\n' "\$!" > "$capture_descendant"
                fi
                "\$@"
                exit "\$?"
                ;;
            *)
                shift
                ;;
        esac
    done
    exit 2
fi
if [ "\$1" = "run" ]; then
    fake_name=""
    fake_managed=""
    fake_run=""
    fake_worktree=""
    fake_owner=""
    fake_remove=0
    fake_cidfile=""
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            --label)
                case "\$2" in
                    io.axoloty.managed-by=*) fake_managed="\${2#*=}" ;;
                    io.axoloty.run-id=*) fake_run="\${2#*=}" ;;
                    io.axoloty.worktree=*) fake_worktree="\${2#*=}" ;;
                    io.axoloty.owner=*) fake_owner="\${2#*=}" ;;
                esac
                shift 2
                ;;
            --env-file)
                cp "\$2" "$capture_env"
                shift 2
                ;;
            --name)
                fake_name="\$2"
                shift 2
                ;;
            --cidfile)
                fake_cidfile="\$2"
                shift 2
                ;;
            -e|--env|-v|-w|--security-opt|--user|--device|-p|--network)
                shift 2
                ;;
            axoloty-dev)
                if [ -n "\$fake_cidfile" ] && [ "\${FAKE_SKIP_CIDFILE:-0}" != "1" ]; then
                    printf '%s\n' fake-container-id > "\$fake_cidfile"
                fi
                if [ "\${FAKE_RUNTIME_BLOCK_LAUNCH:-0}" = "1" ]; then
                    trap 'exit 143' TERM INT
                    while :; do sleep 1; done
                fi
                if [ "\${FAKE_DELAYED_FOREIGN_CONTAINER:-0}" = "1" ]; then
                    (
                        sleep 0.3
                        printf '%s\n' 'FAKE_CONTAINER_LABELS=foreign-owner|foreign-run|foreign-worktree|foreign-process' > "$capture_state"
                        printf 'FAKE_CONTAINER_STATUS=running\n' >> "$capture_state"
                    ) &
                    exit 125
                fi
                if [ -n "\$fake_name" ]; then
                    printf "FAKE_CONTAINER_LABELS='%s'\n" "\$fake_managed|\$fake_run|\$fake_worktree|\$fake_owner" > "$capture_state"
                    printf 'FAKE_CONTAINER_STATUS=running\n' >> "$capture_state"
                    if [ "\${FAKE_FAST_EXIT:-0}" = "1" ] && [ "\$fake_remove" = "1" ]; then
                        rm -f "$capture_state"
                    fi
                fi
                exit "\${FAKE_RUNTIME_EXIT_CODE:-0}"
                ;;
            --rm)
                fake_remove=1
                shift
                ;;
            *) shift ;;
        esac
    done
    exit 2
fi
case "\$*" in
    *chown*)
        if [ "\${FAKE_RECLAIM_FAILURE:-0}" = "1" ]; then exit 42; fi
        ;;
    *)
        if [ "\${FAKE_RUNTIME_EXIT_CODE:-0}" != "0" ]; then exit "\${FAKE_RUNTIME_EXIT_CODE}"; fi
        ;;
esac
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "--env-file" ]; then
        cp "\$2" "$capture_env"
        break
    fi
    shift
done
SH
chmod +x "$fake_bin/fake-sudo" "$fake_bin/fake-podman"

# Managed launches create the container synchronously, verify its immutable ID,
# then attach to start. This avoids ownership inspection racing the runtime's
# storage lock.
: > "$capture"
: > "$capture_sequence"
: > "$capture_argv"
if ! FAKE_RUNTIME_ARGV_CAPTURE=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true; then
    echo "first fake-runtime scenario failed" >&2
    cat "$capture" >&2
    cat "$capture_state" >&2
    exit 1
fi
first_managed_sequence=$(sed -n '1,3p' "$capture_sequence")
[[ "$first_managed_sequence" = $'create\ninspect\nstart' ]]
create_args=$(awk '/^---$/ { if (in_run) exit; first_seen = 0; in_run = 0; next } !first_seen { first_seen = 1; if ($0 == "create") in_run = 1; next } in_run { print }' "$capture_argv")
start_args=$(awk '/^---$/ { if (in_run) exit; first_seen = 0; in_run = 0; next } !first_seen { first_seen = 1; if ($0 == "start") in_run = 1; next } in_run { print }' "$capture_argv")
grep -Fqx -- "--name" <<< "$create_args"
grep -Fqx -- "--attach" <<< "$start_args"
grep -Fqx -- "fake-container-id" <<< "$start_args"

: > "$capture_sequence"
run_expected_failure "container/create-failure" 126 env \
    FAKE_CREATE_FAILURE=1 FAKE_CREATE_EXIT_CODE=126 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
create_failure_status=$RUN_EXPECTED_FAILURE_STATUS
[[ "$create_failure_status" -eq 126 ]]
grep -Fxq create "$capture_sequence"
if grep -Eq '^(start|stop|kill|rm)$' "$capture_sequence"; then
    echo "create failure continued into start or cleanup" >&2
    exit 1
fi

: > "$capture_sequence"
run_expected_failure "container/name-collision" any env \
    FAKE_CREATE_COLLISION=1 CONTAINER_NAME=occupied-container \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
collision_status=$RUN_EXPECTED_FAILURE_STATUS
[[ "$collision_status" -ne 0 ]]
grep -Fxq create "$capture_sequence"
if grep -Eq '^(start|stop|kill|rm)$' "$capture_sequence"; then
    echo "name collision touched a container it did not create" >&2
    exit 1
fi

# Even a colliding container with every reusable ownership field copied cannot
# match this invocation's private instance label.
: > "$capture_sequence"
: > "$capture_state"
run_expected_failure "container/matching-collision" 125 env \
    FAKE_CREATE_COLLISION=1 FAKE_COLLISION_MATCHING_LABELS=1 \
    CONTAINER_NAME=occupied-container AXOLOTY_RUN_ID=reused-run AXOLOTY_OWNER_ID=reused-owner \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
matching_collision_status=$RUN_EXPECTED_FAILURE_STATUS
[[ "$matching_collision_status" -eq 125 ]]
if grep -Eq '^(start|stop|kill|rm)$' "$capture_sequence"; then
    echo "matching-label name collision touched a foreign instance" >&2
    exit 1
fi

# CONTAINER_STDIN changes only the attach mode, not create-time options.
: > "$capture_argv"
CONTAINER_STDIN=1 FAKE_RUNTIME_ARGV_CAPTURE=1 \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
interactive_start_args=$(awk '/^---$/ { if (in_run) exit; first_seen = 0; in_run = 0; next } !first_seen { first_seen = 1; if ($0 == "start") in_run = 1; next } in_run { print }' "$capture_argv")
grep -Fqx -- "--interactive" <<< "$interactive_start_args"

# A successful create without a CID file is adopted by its unique name only
# after all ownership labels match, then started by the recovered immutable ID.
: > "$capture_sequence"
: > "$capture_state"
FAKE_SKIP_CIDFILE=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
missing_cid_sequence=$(sed -n '1,3p' "$capture_sequence")
[[ "$missing_cid_sequence" = $'create\ninspect\ninspect' ]]
grep -Fxq start "$capture_sequence"

# Missing-CID recovery tolerates a transient inspect failure and still starts
# only the container with this invocation's exact ownership labels.
: > "$capture_sequence"
: > "$capture_state"
: > "$capture_inspect_count"
FAKE_SKIP_CIDFILE=1 FAKE_INSPECT_FAILURE_ONCE=1 \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -Fxq start "$capture_sequence"

# A signal can arrive after create commits but before its client returns. The
# wrapper reconciles the unique name and labels before EXIT cleanup.
: > "$capture_sequence"
: > "$capture_state"
rm -f "$capture_api_pid"
FAKE_CREATE_BLOCK_AFTER_COMMIT=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 CONTAINER_TERM_GRACE_SECONDS=1 \
    "$ROOT_DIR/.devcontainer/run.sh" true >"$TEMP_DIR/create-interrupt.log" 2>&1 &
create_runner=$!
wait_for_path "$capture_api_pid" 5
create_api_pid=$(cat "$capture_api_pid")
kill -TERM "$create_runner" 2>/dev/null || true
set +e
wait_bounded "$create_runner" create-interrupt-runner 6
set -e
grep -Fxq rm "$capture_sequence"
if kill -0 "$create_api_pid" 2>/dev/null; then
    create_api_state=$(ps -o stat= -p "$create_api_pid" 2>/dev/null | tr -d ' ' || true)
    case "$create_api_state" in
        ''|Z*) ;;
        *) echo "create helper remained alive after interruption" >&2; exit 1 ;;
    esac
fi

# Cleanup must not call stop for a command that already exited successfully.
: > "$capture_sequence"
: > "$capture_state"
FAKE_STOP_FAIL_IF_EXITED=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
if grep -Fxq stop "$capture_sequence"; then
    echo "cleanup stopped an already-exited container" >&2
    exit 1
fi

# A create failure after the runtime commits the object is reconciled by name
# and exact labels, then cleaned up without ever starting it.
: > "$capture_sequence"
: > "$capture_state"
: > "$capture"
run_expected_failure "container/reconciled-create-failure" 125 env \
    FAKE_CREATE_COMMIT_THEN_FAIL=1 FAKE_CREATE_EXIT_CODE=125 \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
reconciled_create_status=$RUN_EXPECTED_FAILURE_STATUS
[[ "$reconciled_create_status" -eq 125 ]]
grep -q -- '^rm -f fake-container-id$' "$capture"
if grep -q -- '^start ' "$capture"; then
    echo "reconciled create failure unexpectedly started a container" >&2
    exit 1
fi

# A transient ownership inspection failure still removes the created-but-never-
# started container after a later exact-label check succeeds.
: > "$capture_sequence"
: > "$capture_state"
: > "$capture"
: > "$capture_inspect_count"
run_expected_failure "container/inspect-failure" 125 env \
    FAKE_INSPECT_FAILURE_ONCE=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 "$ROOT_DIR/.devcontainer/run.sh" true
inspect_failure_status=$RUN_EXPECTED_FAILURE_STATUS
[[ "$inspect_failure_status" -eq 125 ]]
grep -q -- '^rm -f fake-container-id$' "$capture"

# Start failures preserve the runtime status and clean the verified object.
: > "$capture_sequence"
: > "$capture_state"
: > "$capture"
run_expected_failure "container/start-failure" 127 env \
    FAKE_START_FAILURE=1 FAKE_START_EXIT_CODE=127 \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
start_failure_status=$RUN_EXPECTED_FAILURE_STATUS
[[ "$start_failure_status" -eq 127 ]]
grep -q -- '^start --attach fake-container-id$' "$capture"
grep -q -- '^rm -f fake-container-id$' "$capture"

# A short command's nonzero status remains the attached process status.
set +e
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" sh -c 'exit 1'
short_command_status=$?
set -e
[[ "$short_command_status" -eq 1 ]]

# Mount labeling is opt-in for hosts without active SELinux labeling. The
# checkout, build, SwiftPM, and lease mounts must remain single runtime argv
# elements even when the shared lease root contains spaces.
lease_root="$TEMP_DIR/device leases"
mkdir -p "$lease_root"
: > "$capture_argv"
CONTAINER_MOUNT_SUFFIX= AXOLOTY_DEVICE_LEASE_ROOT="$lease_root" \
FAKE_RUNTIME_ARGV_CAPTURE=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
first_run_args=$(awk '/^---$/ { if (in_run) exit; first_seen = 0; in_run = 0; next } !first_seen { first_seen = 1; if ($0 == "create") in_run = 1; next } in_run { print }' "$capture_argv")
[[ $(printf '%s\n' "$first_run_args" | grep -Fxc -- "$ROOT_DIR:/workspace") -eq 1 ]]
[[ $(printf '%s\n' "$first_run_args" | grep -Fxc -- "$common_git_dir:$common_git_dir") -eq 1 ]]
[[ $(printf '%s\n' "$first_run_args" | grep -Fxc -- "$build_dir:/workspace/.build") -eq 1 ]]
[[ $(printf '%s\n' "$first_run_args" | grep -Fxc -- "$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux:/workspace/.swiftpm-cache") -eq 1 ]]
[[ $(printf '%s\n' "$first_run_args" | grep -Fxc -- "$AXOLOTY_ESP_IDF_CCACHE_DIR:/workspace/.ccache") -eq 1 ]]
[[ $(printf '%s\n' "$first_run_args" | grep -Fxc -- "AXOLOTY_ESP_IDF_CCACHE_DIR=/workspace/.ccache") -eq 1 ]]
[[ $(printf '%s\n' "$first_run_args" | grep -Fxc -- "TOOLING_BUILD_DIR=/workspace/.build/tooling") -eq 1 ]]
[[ $(printf '%s\n' "$first_run_args" | grep -Fxc -- "$lease_root:$lease_root") -eq 1 ]]
if printf '%s\n' "$first_run_args" | grep -Eq -- '(:Z|:z)$'; then
    echo "SELinux mount labels were requested while explicitly disabled" >&2
    exit 1
fi
[[ $(awk -v env="AXOLOTY_DEVICE_LEASE_ROOT=$lease_root" '$0 == "-e" { getline; if ($0 == env) count++ } END { print count + 0 }' <<< "$first_run_args") -eq 1 ]]
[[ $(printf '%s\n' "$first_run_args" | grep -Fxc -- "AXOLOTY_DEVICE_LEASE_ROOT=$lease_root") -eq 1 ]]
if printf '%s\n' "$first_run_args" | grep -Fqx -- "$lease_root"; then
    echo "lease root was split into a separate runtime argument" >&2
    exit 1
fi

# An explicit suffix remains available for hosts whose SELinux state is not
# visible inside the runner. Shared lease storage uses the compatible :z form.
: > "$capture_argv"
CONTAINER_MOUNT_SUFFIX=:Z AXOLOTY_DEVICE_LEASE_ROOT="$lease_root" \
FAKE_RUNTIME_ARGV_CAPTURE=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
forced_run_args=$(awk '/^---$/ { if (in_run) exit; first_seen = 0; in_run = 0; next } !first_seen { first_seen = 1; if ($0 == "create") in_run = 1; next } in_run { print }' "$capture_argv")
[[ $(printf '%s\n' "$forced_run_args" | grep -Fxc -- "$ROOT_DIR:/workspace:Z") -eq 1 ]]
[[ $(printf '%s\n' "$forced_run_args" | grep -Fxc -- "$common_git_dir:$common_git_dir:Z") -eq 1 ]]
[[ $(printf '%s\n' "$forced_run_args" | grep -Fxc -- "$build_dir:/workspace/.build:Z") -eq 1 ]]
[[ $(printf '%s\n' "$forced_run_args" | grep -Fxc -- "$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux:/workspace/.swiftpm-cache:Z") -eq 1 ]]
[[ $(printf '%s\n' "$forced_run_args" | grep -Fxc -- "$AXOLOTY_ESP_IDF_CCACHE_DIR:/workspace/.ccache:z") -eq 1 ]]
[[ $(printf '%s\n' "$forced_run_args" | grep -Fxc -- "$lease_root:$lease_root:z") -eq 1 ]]

FAKE_RUNTIME_EXECUTE_COMMAND=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    CONTAINER_TERM_GRACE_SECONDS=1 \
    "$ROOT_DIR/.devcontainer/run.sh" "$tree_parent" "$tree_child" "$tree_child_pid" "$tree_exited" \
    >"$TEMP_DIR/container-signal.log" 2>&1 &
container_runner=$!
wait_for_path "$tree_child_pid" 5
kill -TERM "$container_runner" 2>/dev/null || true
set +e
wait_bounded "$container_runner" container-runner 5
set -e
[ -e "$tree_exited" ]
child_pid=$(cat "$tree_child_pid")
if kill -0 "$child_pid" 2>/dev/null; then
    echo "container run.sh left an executable descendant" >&2
    exit 1
fi

# An owned container that ignores TERM must be escalated and reaped. The fake
# runtime returns the labels produced by run.sh and records cleanup ordering.
: > "$capture_sequence"
: > "$capture_state"
FAKE_RUNTIME_EXECUTE_COMMAND=1 FAKE_STOP_IGNORES=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 CONTAINER_TERM_GRACE_SECONDS=1 CONTAINER_KILL_GRACE_SECONDS=1 \
    "$ROOT_DIR/.devcontainer/run.sh" "$tree_parent" "$tree_child" "$tree_child_pid" "$tree_exited" \
    >"$TEMP_DIR/owned-container.log" 2>&1 &
owned_runner=$!
wait_for_path "$tree_child_pid" 5
kill -TERM "$owned_runner" 2>/dev/null || true
set +e
wait_bounded "$owned_runner" owned-container-runner 5
set -e
expected_sequence=$'inspect\nstop\ninspect-status\nkill\nrm'
grep -q -- '^stop --time 1 ' "$capture" || { cat "$capture" >&2; exit 1; }
grep -q -- '^inspect --format {{.State.Status}} ' "$capture" || { cat "$capture" >&2; exit 1; }
if [ "${FAKE_STOP_IGNORES:-0}" = "1" ]; then
    grep -q -- '^kill ' "$capture" || { cat "$capture" >&2; exit 1; }
fi
grep -q -- '^rm -f ' "$capture" || { cat "$capture" >&2; exit 1; }

# A fast successful command must remain inspectable until run.sh verifies its
# ownership and removes it. Runtimes erase an --rm container before the wrapper
# can inspect labels, which previously turned `true` into exit 125.
: > "$capture_sequence"
: > "$capture_state"
: > "$capture"
set +e
FAKE_FAST_EXIT=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 CONTAINER_OWNERSHIP_TIMEOUT_SECONDS=1 \
    "$ROOT_DIR/.devcontainer/run.sh" true
fast_exit_status=$?
set -e
if [[ "$fast_exit_status" -ne 0 ]]; then
    echo "fast successful container exited with $fast_exit_status" >&2
    exit 1
fi
grep -q -- '^rm -f ' "$capture" || { cat "$capture" >&2; exit 1; }
grep -q -- '^rm -f fake-container-id$' "$capture" || { cat "$capture" >&2; exit 1; }
if grep -q -- '^create .*--rm' "$capture"; then
    echo "managed fast container still enabled runtime auto-removal" >&2
    exit 1
fi

# A runtime client may exit after leaving a helper in its process group. The
# wrapper must drain that descendant before reporting completion.
: > "$capture_state"
: > "$capture"
rm -f "$capture_descendant"
FAKE_RUNTIME_EXECUTE_COMMAND=1 FAKE_RUNTIME_LEAK_DESCENDANT=1 \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    CONTAINER_TERM_GRACE_SECONDS=1 CONTAINER_KILL_GRACE_SECONDS=1 \
    "$ROOT_DIR/.devcontainer/run.sh" true
wait_for_path "$capture_descendant" 2
descendant_pid=$(cat "$capture_descendant")
if kill -0 "$descendant_pid" 2>/dev/null; then
    descendant_state=$(ps -o stat= -p "$descendant_pid" 2>/dev/null | tr -d ' ' || true)
    case "$descendant_state" in
        ''|Z*) ;;
        *) echo "runtime descendant remained alive after completion" >&2; exit 1 ;;
    esac
fi

# Runtime API failures are bounded and turn a successful command into a
# cleanup failure instead of leaking silently.
: > "$capture_state"
: > "$capture"
cleanup_started=$(date +%s)
run_expected_failure "container/blocked-cleanup" 125 env \
    FAKE_CLEANUP_BLOCK=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 CONTAINER_API_TIMEOUT_SECONDS=1 \
    CONTAINER_TERM_GRACE_SECONDS=1 CONTAINER_KILL_GRACE_SECONDS=1 \
    "$ROOT_DIR/.devcontainer/run.sh" true
blocked_cleanup_status=$RUN_EXPECTED_FAILURE_STATUS
cleanup_elapsed=$(( $(date +%s) - cleanup_started ))
[[ "$blocked_cleanup_status" -eq 125 ]]
[[ "$cleanup_elapsed" -le 8 ]]
grep -q -- '^rm -f fake-container-id$' "$capture"
: > "$capture_state"

# A failed removal followed by an inconclusive existence query is itself a
# cleanup failure; it must never preserve a successful command status.
: > "$capture_state"
: > "$capture"
run_expected_failure "container/inconclusive-cleanup" 125 env \
    FAKE_RM_FAILURE=1 FAKE_EXISTS_FAILURE=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 CONTAINER_API_TIMEOUT_SECONDS=1 \
    "$ROOT_DIR/.devcontainer/run.sh" true
inconclusive_cleanup_status=$RUN_EXPECTED_FAILURE_STATUS
[[ "$inconclusive_cleanup_status" -eq 125 ]]

# Signals received while an inspect helper is active must terminate and reap
# that helper before run.sh exits.
: > "$capture_state"
: > "$capture"
rm -f "$capture_api_pid"
FAKE_INSPECT_BLOCK=1 CONTAINER_RUNTIME="$fake_bin/fake-podman" \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 CONTAINER_API_TIMEOUT_SECONDS=1 \
    CONTAINER_OWNERSHIP_TIMEOUT_SECONDS=1 CONTAINER_TERM_GRACE_SECONDS=1 \
    "$ROOT_DIR/.devcontainer/run.sh" true >"$TEMP_DIR/api-interrupt.log" 2>&1 &
api_runner=$!
wait_for_path "$capture_api_pid" 5
api_pid=$(cat "$capture_api_pid")
kill -TERM "$api_runner" 2>/dev/null || true
set +e
wait_bounded "$api_runner" api-interrupt-runner 6
set -e
if kill -0 "$api_pid" 2>/dev/null; then
    api_state=$(ps -o stat= -p "$api_pid" 2>/dev/null | tr -d ' ' || true)
    case "$api_state" in
        ''|Z*) ;;
        *) echo "runtime API helper remained alive after interruption" >&2; exit 1 ;;
    esac
fi

device="$TEMP_DIR/device"
: > "$device"
: > "$capture_env"
SUDO_CANDIDATES="$fake_bin/fake-sudo" \
CONTAINER_DEVICES="$device" CONTAINER_RUNTIME="$fake_bin/fake-podman" \
CONTAINER_ENV_VARS="EMBEDDED_SKIP_BUILD EMBEDDED_BUILD_DIR" \
EMBEDDED_SKIP_BUILD=1 EMBEDDED_BUILD_DIR=/workspace/.build/embedded-swift \
    CONTAINER_RECLAIM_BUILD_DIR=1 BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
device_capture=$(awk '/--device .*--privileged/{capture=1} capture{print}' "$capture")
grep -q -- '--privileged' <<< "$device_capture"
grep -q -- "--device $device" <<< "$device_capture"
if printf '%s\n' "$device_capture" | grep -q -- '^run .*--user '; then
    echo "device run unexpectedly set an ordinary user" >&2
    exit 1
fi
grep -q -- '--env-file ' <<< "$device_capture"
grep -qx -- 'EMBEDDED_SKIP_BUILD=1' "$capture_env"
grep -qx -- 'EMBEDDED_BUILD_DIR=/workspace/.build/embedded-swift' "$capture_env"
grep -q -- 'chown -R ' "$capture"
grep -q -- 'save axoloty-dev' "$capture"
grep -q -- 'load' "$capture"
save_line=$(grep -n -- 'save axoloty-dev' "$capture" | cut -d: -f1)
run_line=$(grep -n -m1 -- '^create .*--device ' "$capture" | cut -d: -f1)
[[ "$save_line" -lt "$run_line" ]]

# Host Podman is opt-in: ordinary project commands do not receive a host
# socket, while the wire bridge reuses an already-running service and keeps
# the repository's host path as the container workdir for remote bind mounts.
: > "$capture"
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
if grep -Eq -- 'CONTAINER_HOST|DOCKER_HOST' "$capture"; then
    echo "ordinary container run unexpectedly enabled host Podman" >&2
    exit 1
fi

# Every external run has a deterministic owned name and run label; the fake
# runtime inspects the construction without contacting Podman.
: > "$capture"
AXOLOTY_RUN_ID=issue-551 \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '--name ' "$capture"
grep -q -- '--label io.axoloty.managed-by=axoloty-run.sh' "$capture"
grep -q -- '--label io.axoloty.run-id=issue-551' "$capture"
grep -q -- "--label io.axoloty.worktree=$expected_worktree_name" "$capture"
grep -q -- '--label io.axoloty.owner=' "$capture"
grep -q -- '--label io.axoloty.instance=' "$capture"

# A synchronous create collision is reconciled by name but cannot make run.sh
# remove an unowned container or proceed to start it.
: > "$capture_sequence"
if FAKE_CREATE_COLLISION=1 CONTAINER_NAME=colliding-container AXOLOTY_RUN_ID=owned-run \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true; then
    :
fi
if grep -Eq '^(start|stop|kill|rm)$' "$capture_sequence"; then
    echo "foreign container collision triggered cleanup" >&2
    exit 1
fi

host_socket="$TEMP_DIR/podman socket.sock"
python3 - "$host_socket" <<'PY' &
import socket
import sys
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen(1)
server.accept()
PY
socket_server=$!
for _ in 1 2 3 4 5; do
    [ -S "$host_socket" ] && break
    sleep 0.1
done
: > "$capture"
AXOLOTY_HOST_RUNTIME_BRIDGE=1 CONTAINER_HOST="unix://$host_socket" \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- "-w $ROOT_DIR" "$capture"
grep -q -- "AXOLOTY_DEVCONTAINER=1" "$capture"
grep -q -- "CONTAINER_RUNTIME=$ROOT_DIR/.devcontainer/container-runtime-remote.sh" "$capture"
grep -q -- "AXOLOTY_HOST_RUNTIME_BRIDGE=1" "$capture"
grep -q -- "DOCKER_HOST=unix://$host_socket" "$capture"
grep -q -- "BUILD_DIR=$build_dir" "$capture"
grep -q -- "TOOLING_BUILD_DIR=$build_dir/tooling" "$capture"
grep -q -- "SPM_CACHE_DIR=$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux" "$capture"
grep -q -- "AXOLOTY_ESP_IDF_CCACHE_DIR=$AXOLOTY_ESP_IDF_CCACHE_DIR" "$capture"
grep -q -- "REPOSITORY_NAME=$expected_repository_name" "$capture"
grep -q -- "TMPDIR=$ROOT_DIR/.testing/tmp" "$capture"
grep -Eq -- 'WIRE_RUN_ID=[0-9]+-[0-9]+' "$capture"
grep -q -- "$build_dir:$build_dir" "$capture"
grep -q -- "$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux:$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux" "$capture"
grep -q -- "$AXOLOTY_ESP_IDF_CCACHE_DIR:$AXOLOTY_ESP_IDF_CCACHE_DIR" "$capture"
grep -q -- '--security-opt label=disable' "$capture"
[ -S "$host_socket" ]

# Execute a local observer through the fake container boundary. This verifies
# child visibility of the complete bridge contract without contacting Podman.
bridge_observer="$TEMP_DIR/observe-bridge-environment.sh"
cat > "$bridge_observer" <<'SH'
#!/bin/sh
set -eu
socket_path=${DOCKER_HOST#unix://}
[ "$AXOLOTY_DEVCONTAINER" = "1" ]
[ "$AXOLOTY_HOST_RUNTIME_BRIDGE" = "1" ]
[ -x "$CONTAINER_RUNTIME" ]
[ -S "$socket_path" ]
printf '%s\n' \
    "$AXOLOTY_DEVCONTAINER" \
    "$AXOLOTY_HOST_RUNTIME_BRIDGE" \
    "$CONTAINER_RUNTIME" \
    "$DOCKER_HOST" > "$1"
SH
chmod +x "$bridge_observer"
FAKE_RUNTIME_EXECUTE_COMMAND=1 \
AXOLOTY_HOST_RUNTIME_BRIDGE=1 CONTAINER_HOST="unix://$host_socket" \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" "$bridge_observer" "$capture_child_env"
{
    IFS= read -r observed_devcontainer
    IFS= read -r observed_bridge
    IFS= read -r observed_runtime
    IFS= read -r observed_docker_host
} < "$capture_child_env"
[[ "$observed_devcontainer" = "1" ]]
[[ "$observed_bridge" = "1" ]]
[[ "$observed_runtime" = "$ROOT_DIR/.devcontainer/container-runtime-remote.sh" ]]
[[ "$observed_docker_host" = "unix://$host_socket" ]]
kill "$socket_server" 2>/dev/null || true
wait_bounded "$socket_server" bridge-socket-server 5 || true
socket_server=""

# CI already uses worktree-local cache paths. Each destination must appear
# once rather than as both a same-path mount and a worktree-relative alias.
: > "$capture"
AXOLOTY_HOST_RUNTIME_BRIDGE=1 CONTAINER_HOST="unix://$host_socket" \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$ROOT_DIR/.build" \
    SPM_CACHE_DIR="$ROOT_DIR/.swiftpm-cache" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
[[ $(grep -o -- "$ROOT_DIR/.build:$ROOT_DIR/.build" "$capture" | wc -l) -eq 1 ]]
[[ $(grep -o -- "$ROOT_DIR/.swiftpm-cache:$ROOT_DIR/.swiftpm-cache" "$capture" | wc -l) -eq 1 ]]

# When no socket exists, the bridge starts a temporary service and removes it
# after the container exits.
rm -f "$host_socket"
: > "$capture"
AXOLOTY_HOST_RUNTIME_BRIDGE=1 CONTAINER_HOST="unix://$host_socket" \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
[ ! -e "$host_socket" ]

# Matching rootless and rootful image IDs do not transfer the image again.
: > "$capture"
FAKE_RUNTIME_ROOTFUL_IMAGE_ID=rootless-image \
SUDO_CANDIDATES="$fake_bin/fake-sudo" \
CONTAINER_DEVICES="$device" CONTAINER_RUNTIME="$fake_bin/fake-podman" \
BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
if grep -q -- 'save axoloty-dev\|load' "$capture"; then
    echo "matching rootful image was transferred again" >&2
    exit 1
fi

# Optional devices are forwarded when present and ignored when absent.
: > "$capture"
CONTAINER_OPTIONAL_DEVICES="$device $TEMP_DIR/absent-device" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- "--user $(id -u):$(id -g)" "$capture"
grep -q -- '--env HOME=/tmp' "$capture"

# Reclaim failures are warnings and must not replace the container command's status.
: > "$capture"
set +e
FAKE_RECLAIM_FAILURE=1 FAKE_RUNTIME_EXIT_CODE=7 \
SUDO_CANDIDATES="$fake_bin/fake-sudo" CONTAINER_DEVICES="$device" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" CONTAINER_RECLAIM_BUILD_DIR=1 \
BUILD_DIR="$build_dir" BUILD_LOCK=0 "$ROOT_DIR/.devcontainer/run.sh" true
reclaim_status=$?
set -e
[[ "$reclaim_status" -eq 7 ]]
grep -q -- "--device $device" "$capture"
if grep -q -- "$TEMP_DIR/absent-device" "$capture"; then
    echo "absent optional device was forwarded" >&2
    exit 1
fi
if grep -q -- 'save axoloty-dev\|load' "$capture"; then
    echo "rootless optional-device run synchronized an image" >&2
    exit 1
fi

if CONTAINER_RUNTIME="$fake_bin/fake-podman" CONTAINER_ENV_VARS=1 \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected an invalid container environment name to fail" >&2
    exit 1
fi

# --- CONTAINER_PORTS tests ---

# Single port mapping produces -p flag.
: > "$capture"
CONTAINER_PORTS="127.0.0.1:1883:1883" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '-p 127.0.0.1:1883:1883' "$capture"

# Multiple port mappings each produce -p flags.
: > "$capture"
CONTAINER_PORTS="127.0.0.1:1883:1883 127.0.0.1:8765:8765" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '-p 127.0.0.1:1883:1883' "$capture"
grep -q -- '-p 127.0.0.1:8765:8765' "$capture"

# No port flags when CONTAINER_PORTS is not set.
: > "$capture"
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
if grep -q -- '-p ' "$capture"; then
    echo "unexpected -p flag in ordinary command" >&2
    exit 1
fi

# Invalid port spec with shell metacharacter is rejected.
if CONTAINER_PORTS="127.0.0.1:1883:1883;echo pwned" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected shell-metacharacter port spec to fail" >&2
    exit 1
fi

# Newline in port spec is rejected.
if CONTAINER_PORTS="127.0.0.1:1883:1883
8765" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected newline port spec to fail" >&2
    exit 1
fi

# --- CONTAINER_NETWORK tests ---

# Host networking produces the expected runtime flag.
: > "$capture"
CONTAINER_NETWORK=host \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '--network host' "$capture"

# Arbitrary runtime flags are rejected.
if CONTAINER_NETWORK='host --privileged' \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected invalid container network to fail" >&2
    exit 1
fi

# --- CONTAINER_STDIN tests ---

# CONTAINER_STDIN=1 produces -i.
: > "$capture"
CONTAINER_STDIN=1 \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '-i' "$capture"

# CONTAINER_STDIN=1 never produces -t.
if grep -qw -- '-t' "$capture"; then
    echo "unexpected -t flag with CONTAINER_STDIN=1" >&2
    exit 1
fi

# No -i flag when CONTAINER_STDIN is not set.
: > "$capture"
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
run_args=$(cat "$capture")
if echo "$run_args" | grep -qw -- '-i'; then
    echo "unexpected -i flag in ordinary command" >&2
    exit 1
fi
