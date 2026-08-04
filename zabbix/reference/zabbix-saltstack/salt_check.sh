#!/usr/bin/env bash
#
# salt_check.sh
#
# Single "master item" check script for Zabbix. Emits one JSON document
# covering:
#   1. process   - is salt-minion running
#   2. hung      - is the minion responsive / are jobs stuck
#   3. highstate - did the last recorded highstate succeed, and how stale is it
#
# Designed to be called once per interval by Zabbix (via a master item), with
# individual metrics pulled out as dependent items using JSONPath
# preprocessing, rather than shelling out separately for every metric.
#
# Must run as root (or via sudo) to read salt-minion's PID/cgroup info and to
# call salt-call against the minion's own config/cache. See the sudoers
# snippet shipped alongside this script.
#
# Requires: jq, bc, coreutils. Optional: systemd (falls back to pgrep).
#
set -uo pipefail

STATUS_FILE="/var/lib/zabbix-salt/highstate-status.json"
LOCK_FILE="/var/run/salt-highstate.lock"
LOCK_INFO="${LOCK_FILE}.info"

# --- tunables (can be overridden via environment if you wrap this script) ---
PING_TIMEOUT="${SALT_PING_TIMEOUT:-15}"
STUCK_JOB_THRESHOLD="${SALT_STUCK_JOB_THRESHOLD:-1800}"   # seconds a job may run before it's "stuck"
HUNG_RUN_THRESHOLD="${SALT_HUNG_RUN_THRESHOLD:-3600}"     # seconds the wrapper's lock may be held before flagging as hung
HIGHSTATE_MAX_AGE="${SALT_HIGHSTATE_MAX_AGE:-5400}"       # informational only; actual staleness trigger lives in the Zabbix template

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---------------------------------------------------------------------------
# 1. process running?
# ---------------------------------------------------------------------------
PROC_RUNNING=0
PID=0
PROC_STATE=""
UPTIME_SECONDS=0

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^salt-minion\.service'; then
    if systemctl is-active --quiet salt-minion; then
        PROC_RUNNING=1
        PID=$(systemctl show -p MainPID --value salt-minion 2>/dev/null || echo 0)
    fi
fi

if [[ "$PROC_RUNNING" -eq 0 ]]; then
    FALLBACK_PID=$(pgrep -f '/usr/bin/salt-minion' -o 2>/dev/null || true)
    if [[ -n "$FALLBACK_PID" ]]; then
        PROC_RUNNING=1
        PID="$FALLBACK_PID"
    fi
fi

if [[ "$PROC_RUNNING" -eq 1 && -n "$PID" && "$PID" != "0" && -d "/proc/$PID" ]]; then
    PROC_STATE=$(awk '{print $3}' "/proc/$PID/stat" 2>/dev/null)
    START_TICKS=$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null)
    CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
    SYS_UPTIME=$(awk '{print $1}' /proc/uptime 2>/dev/null || echo 0)
    if [[ -n "$START_TICKS" ]]; then
        PROC_START_SEC=$(echo "$START_TICKS / $CLK_TCK" | bc 2>/dev/null || echo 0)
        UPTIME_SECONDS=$(echo "($SYS_UPTIME - $PROC_START_SEC)/1" | bc 2>/dev/null || echo 0)
    fi
else
    PROC_RUNNING=0
    PID=0
fi

# ---------------------------------------------------------------------------
# 2. hung?
#    - salt-call test.ping proves the Python/state engine still executes
#    - saltutil.running catches jobs stuck mid-execution on the minion
#    - lock file from the highstate wrapper catches a highstate run that's
#      been going for way too long
# ---------------------------------------------------------------------------
PING_OK=0
PING_MS=0
STUCK_JOBS=0
LONGEST_JOB_SECONDS=0
HIGHSTATE_RUN_HUNG=0

if [[ "$PROC_RUNNING" -eq 1 ]]; then
    T0=$(date +%s%3N)
    PING_TMP=$(mktemp)
    if timeout "$PING_TIMEOUT" salt-call --local test.ping --out=json --log-level=quiet > "$PING_TMP" 2>/dev/null; then
        if command -v jq >/dev/null 2>&1 && [[ "$(jq -r '.local' "$PING_TMP" 2>/dev/null)" == "true" ]]; then
            PING_OK=1
        fi
    fi
    T1=$(date +%s%3N)
    PING_MS=$((T1 - T0))
    rm -f "$PING_TMP"

    if command -v jq >/dev/null 2>&1; then
        RUNNING_JSON=$(timeout "$PING_TIMEOUT" salt-call --local saltutil.running --out=json --log-level=quiet 2>/dev/null)
        if [[ -n "$RUNNING_JSON" ]]; then
            NOW=$(date +%s)
            while IFS= read -r st; do
                [[ -z "$st" ]] && continue
                JOB_EPOCH=$(date -d "$st" +%s 2>/dev/null || echo "$NOW")
                AGE=$((NOW - JOB_EPOCH))
                [[ "$AGE" -gt "$LONGEST_JOB_SECONDS" ]] && LONGEST_JOB_SECONDS="$AGE"
                [[ "$AGE" -gt "$STUCK_JOB_THRESHOLD" ]] && STUCK_JOBS=$((STUCK_JOBS + 1))
            done < <(echo "$RUNNING_JSON" | jq -r '.local[]?.start_time // empty' 2>/dev/null)
        fi
    fi
fi

if [[ -f "$LOCK_INFO" ]] && command -v jq >/dev/null 2>&1; then
    RUN_START=$(jq -r '.start_epoch // 0' "$LOCK_INFO" 2>/dev/null || echo 0)
    if [[ "$RUN_START" -gt 0 ]]; then
        NOW=$(date +%s)
        RUN_AGE=$((NOW - RUN_START))
        [[ "$RUN_AGE" -gt "$HUNG_RUN_THRESHOLD" ]] && HIGHSTATE_RUN_HUNG=1
    fi
fi

# ---------------------------------------------------------------------------
# 3. last highstate result (produced by salt-highstate-wrapper.sh)
# ---------------------------------------------------------------------------
STATUS_FOUND=0
HS_SUCCESS=0
HS_LAST_EPOCH=0
HS_AGE=999999999   # sentinel: "no highstate ever recorded" -- large enough to trip any staleness trigger
HS_DURATION=0
HS_TOTAL=0
HS_FAILED=0
HS_ERROR=""

if [[ -f "$STATUS_FILE" ]] && command -v jq >/dev/null 2>&1; then
    STATUS_FOUND=1
    HS_LAST_EPOCH=$(jq -r '.last_run_epoch // 0' "$STATUS_FILE")
    HS_SUCCESS=$(jq -r '.success // 0' "$STATUS_FILE")
    HS_DURATION=$(jq -r '.duration_seconds // 0' "$STATUS_FILE")
    HS_TOTAL=$(jq -r '.total_states // 0' "$STATUS_FILE")
    HS_FAILED=$(jq -r '.failed_states // 0' "$STATUS_FILE")
    HS_ERROR=$(jq -r '.error // ""' "$STATUS_FILE")
    NOW=$(date +%s)
    HS_AGE=$((NOW - HS_LAST_EPOCH))
fi

cat <<EOF
{
  "process": {
    "running": ${PROC_RUNNING},
    "pid": ${PID:-0},
    "state": "${PROC_STATE}",
    "uptime_seconds": ${UPTIME_SECONDS:-0}
  },
  "hung": {
    "ping_ok": ${PING_OK},
    "ping_response_ms": ${PING_MS},
    "stuck_jobs": ${STUCK_JOBS},
    "longest_running_job_seconds": ${LONGEST_JOB_SECONDS},
    "highstate_run_hung": ${HIGHSTATE_RUN_HUNG}
  },
  "highstate": {
    "status_file_found": ${STATUS_FOUND},
    "success": ${HS_SUCCESS},
    "last_run_epoch": ${HS_LAST_EPOCH},
    "age_seconds": ${HS_AGE},
    "duration_seconds": ${HS_DURATION},
    "total_states": ${HS_TOTAL},
    "failed_states": ${HS_FAILED},
    "max_age_hint": ${HIGHSTATE_MAX_AGE},
    "error": "$(json_escape "$HS_ERROR")"
  }
}
EOF
