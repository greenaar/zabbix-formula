import json
import os
import time

__virtualname__ = "zabbix_status"

STATUS_FILE = "/var/lib/zabbix-salt/highstate-status.json"


def returner(ret):
    """
    Called automatically by the minion after the scheduled job that
    specifies `returner: zabbix_status` finishes. No external process
    needed -- the minion daemon calls this in-process.
    """
    result = ret.get("return") or {}
    total = len(result) if isinstance(result, dict) else 0
    failed = 0
    if isinstance(result, dict):
        failed = sum(
            1 for s in result.values()
            if isinstance(s, dict) and s.get("result") is False
        )

    success = 1 if (total > 0 and failed == 0) else 0
    if total == 0:
        error = "highstate returned no states (retcode {})".format(ret.get("retcode"))
    elif failed:
        error = "{} of {} states failed".format(failed, total)
    else:
        error = ""

    status = {
        "last_run_epoch": int(time.time()),
        "exit_code": ret.get("retcode", 0),
        "success": success,
        "total_states": total,
        "failed_states": failed,
        "error": error,
    }

    os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
    tmp = STATUS_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(status, fh)
    os.replace(tmp, STATUS_FILE)   # atomic, so the check script never reads a half-written file
