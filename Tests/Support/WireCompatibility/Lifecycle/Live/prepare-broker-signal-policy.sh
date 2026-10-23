#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Hosted Ubuntu attaches its Mosquitto profile even to rootless containers.
# Permit their crun supervisor to stop the broker; retain all other confinement.
set -euo pipefail
POLICY_ROOT="${APPARMOR_POLICY_ROOT:-/etc/apparmor.d}"
ENABLED_FILE="${APPARMOR_ENABLED_FILE:-/sys/module/apparmor/parameters/enabled}"
if [ ! -r "$ENABLED_FILE" ] || [ "$(cat "$ENABLED_FILE")" != Y ]; then
    echo 'AppArmor is inactive; no broker signal policy is needed'
    exit 0
fi
profile="$POLICY_ROOT/mosquitto"
if [ ! -f "$profile" ]; then
    echo 'No host Mosquitto AppArmor profile; broker preflight will check signaling'
    exit 0
fi
if ! grep -Eq 'include[[:space:]]+(if[[:space:]]+exists[[:space:]]+)?<local/mosquitto>' "$profile"; then
    echo "Cannot add narrow signal rule: $profile does not include local/mosquitto" >&2
    exit 1
fi
rule='signal (receive) set=(term,kill) peer=crun,'
fragment="$POLICY_ROOT/local/mosquitto"
sudo -n mkdir -p "$POLICY_ROOT/local"
if ! sudo -n grep -Fqx "$rule" "$fragment" 2>/dev/null; then
    printf '\n# Axoloty live-wire CI: allow rootless crun broker shutdown.\n%s\n' "$rule" | sudo -n tee -a "$fragment" >/dev/null
fi
timeout 15s sudo -n apparmor_parser -r "$profile"
echo 'Mosquitto confinement retained; TERM/KILL from crun permitted for live-wire CI'
