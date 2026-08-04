#!/usr/bin/env bash
#
# salt-highstate-wrapper.sh
#
# Runs `salt-call state.highstate` and records the outcome to a status file
# that the Zabbix check script (salt_check.sh) reads. Salt does not persist
# "last highstate result" anywhere by default, so this wrapper is what makes
# that check possible.
#
# Intended to be run by the salt-highstate.timer systemd unit (or cron) in
# place of a bare `salt-call state.highstate`. Runs as root.
#
# Requires: jq
#
set -uo pipefail

STATUS_DIR="/var/lib/zabbix-salt"
STATUS_FILE="${STATUS_DIR}/highstate-status.json"
LOCK_FILE="/var/run/salt-highstate.lock"
LOCK_INFO="${LOCK_FILE}.info"
LOG_FILE="/var/log/salt-highstate-wrapper.log"
MAX_RUNTIME=3600   # kill the highstate if it runs longer than this (seconds)

mkdir -p "$STATUS_DIR"

log() { echo "$(date -Is) $*" >> "$LOG_FILE"; }

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "another highstate run is already in progress, skipping this invocation"
    exit 1
fi

START_EPOCH=$(date +%s)
echo "{\"start_epoch\": ${START_EPOCH}, \"pid\": $$}" > "$LOCK_INFO"

OUTPUT_FILE=$(mktemp /tmp/salt-highstate-output.XXXXXX)
trap 'rm -f "$OUTPUT_FILE" "$LOCK_INFO"' EXIT

# NOTE: uses --local (masterless-style local execution). If this minion is
# managed by a Salt master and you want the highstate to go through the
# normal master-driven path instead, drop --local.
timeout "$MAX_RUNTIME" salt-call --local state.highstate --out=json --log-level=quiet \
    > "$OUTPUT_FILE" 2>&1
EXIT_CODE=$?

END_EPOCH=$(date +%s)
DURATION=$((END_EPOCH - START_EPOCH))

SUCCESS=0
TOTAL_STATES=0
FAILED_STATES=0
ERROR_MSG=""

if ! command -v jq >/dev/null 2>&1; then
    ERROR_MSG="jq is not installed on this host"
elif [[ $EXIT_CODE -ne 0 ]]; then
    ERROR_MSG="salt-call exited with code ${EXIT_CODE} (timeout or error)"
else
    # salt-call --out=json wraps the real result under a single top-level key
    # (usually "local"). Pull whatever that first value is.
    RESULT_JSON=$(jq -c 'to_entries[0].value' "$OUTPUT_FILE" 2>/dev/null)
    if [[ -z "$RESULT_JSON" || "$RESULT_JSON" == "null" ]]; then
        ERROR_MSG="could not parse highstate JSON output"
    else
        TOTAL_STATES=$(echo "$RESULT_JSON" | jq 'length' 2>/dev/null || echo 0)
        FAILED_STATES=$(echo "$RESULT_JSON" | jq '[.[] | select(.result == false)] | length' 2>/dev/null || echo 0)
        if [[ "$TOTAL_STATES" -gt 0 && "$FAILED_STATES" -eq 0 ]]; then
            SUCCESS=1
        else
            ERROR_MSG="${FAILED_STATES} of ${TOTAL_STATES} states failed"
        fi
    fi
fi

ERROR_MSG_ESCAPED=$(printf '%s' "$ERROR_MSG" | sed 's/\\/\\\\/g; s/"/\\"/g')

cat > "$STATUS_FILE" <<EOF
{
  "last_run_epoch": ${END_EPOCH},
  "start_epoch": ${START_EPOCH},
  "duration_seconds": ${DURATION},
  "exit_code": ${EXIT_CODE},
  "success": ${SUCCESS},
  "total_states": ${TOTAL_STATES:-0},
  "failed_states": ${FAILED_STATES:-0},
  "error": "${ERROR_MSG_ESCAPED}"
}
EOF

cp "$OUTPUT_FILE" "${STATUS_DIR}/last-highstate-output.json" 2>/dev/null || true

log "highstate run finished: success=${SUCCESS} exit_code=${EXIT_CODE} duration=${DURATION}s failed_states=${FAILED_STATES}/${TOTAL_STATES}"

exit "$EXIT_CODE"
