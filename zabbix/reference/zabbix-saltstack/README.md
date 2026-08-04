# Salt Minion Health Check for Zabbix 7.4+

Checks a local `salt-minion` for three things:

1. **Running** — process is active (systemd, falls back to `pgrep`)
2. **Not hung** — responds to a local `salt-call test.ping`, has no jobs
   stuck executing, and doesn't have a highstate run stuck mid-flight
3. **Last highstate succeeded** — read from a status file written by a
   wrapper script, since Salt itself doesn't remember highstate history

Implemented as a Zabbix **master item + dependent items** (one script
execution per polling interval, JSON split out via JSONPath preprocessing)
rather than one `UserParameter` per metric.

## Why something has to write a status file

Vanilla `salt-minion` has no built-in record of "did the last highstate
succeed." Something has to run the highstate and record the outcome to
`/var/lib/zabbix-salt/highstate-status.json`, which `salt_check.sh` reads.
There are two ways to do that — pick one:

- **Recommended: Salt's own scheduler + a returner** (`salt/` folder). The
  minion daemon runs the highstate itself on an interval and calls a
  returner when it finishes — no external process spawned each time, and a
  hung/deadlocked minion can't run its own scheduler either, which makes
  "highstate went stale" double as a decent hung-minion signal.
- **Alternative: cron/systemd + wrapper script** (`alternative-cron-method/`
  folder). Use this if you don't want to touch `_returners/` (e.g. you
  don't control the minion's file_roots, or highstates are triggered
  centrally from the master in a way that's awkward to attach a returner
  to). A systemd timer runs `salt-call state.highstate` and a wrapper
  script parses the output and writes the same status file.

Either way, **whichever method you pick needs to be what actually triggers
your highstates.** If highstates keep running some other way too, the
status file just reflects whichever method wrote it last — not a problem
per se, but worth knowing.

`salt_check.sh` and everything under `zabbix/` are identical either way —
they only care that the status file exists and is fresh, not how it got
there.

## Files

```
scripts/salt_check.sh                          -> /etc/zabbix/scripts/salt_check.sh
zabbix/salt_monitoring.conf                     -> /etc/zabbix/zabbix_agent2.d/plugins.d/salt_monitoring.conf
zabbix/sudoers-zabbix-salt                      -> /etc/sudoers.d/zabbix-salt
zabbix/salt_minion_health_template.yaml         -> import into Zabbix under Data collection > Templates

# recommended: scheduler + returner
salt/_returners/zabbix_status.py                -> <file_roots>/_returners/zabbix_status.py (e.g. /srv/salt/_returners/)
salt/schedule.conf                              -> /etc/salt/minion.d/schedule.conf

# alternative: cron/systemd + wrapper
alternative-cron-method/salt-highstate-wrapper.sh -> /usr/local/bin/salt-highstate-wrapper.sh
alternative-cron-method/salt-highstate.service    -> /etc/systemd/system/salt-highstate.service
alternative-cron-method/salt-highstate.timer      -> /etc/systemd/system/salt-highstate.timer
```

## Install

```bash
# dependencies
apt install jq bc   # or: yum install jq bc

# check script
install -o root -g root -m 0755 scripts/salt_check.sh /etc/zabbix/scripts/salt_check.sh

# sudo access for the zabbix agent user
install -m 0440 zabbix/sudoers-zabbix-salt /etc/sudoers.d/zabbix-salt
visudo -c

# agent config
mkdir -p /etc/zabbix/zabbix_agent2.d/plugins.d
install -m 0644 zabbix/salt_monitoring.conf /etc/zabbix/zabbix_agent2.d/plugins.d/salt_monitoring.conf
systemctl restart zabbix-agent2
```

### Recommended: scheduler + returner

```bash
mkdir -p /srv/salt/_returners
install -m 0644 salt/_returners/zabbix_status.py /srv/salt/_returners/zabbix_status.py
install -m 0644 salt/schedule.conf /etc/salt/minion.d/schedule.conf

salt-call --local saltutil.sync_returners
systemctl restart salt-minion
```

### Alternative: cron/systemd + wrapper

```bash
install -o root -g root -m 0755 alternative-cron-method/salt-highstate-wrapper.sh /usr/local/bin/salt-highstate-wrapper.sh
install -m 0644 alternative-cron-method/salt-highstate.service /etc/systemd/system/
install -m 0644 alternative-cron-method/salt-highstate.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now salt-highstate.timer
```

Then in Zabbix: **Data collection > Templates > Import** →
`salt_minion_health_template.yaml`, and link the template to the host.
Test the raw item manually first with:

```bash
zabbix_get -s <host> -k salt.check
```

## Tuning

- `{$SALT.HIGHSTATE.MAXAGE}` template macro (default 5400s / 90min) — how
  stale a highstate record can get before alerting. Set to roughly 2x your
  actual highstate interval.
- `minutes:` in `salt/schedule.conf` (default 30) — how often highstates
  run. (If using the alternative method instead, it's `OnUnitActiveSec` in
  `salt-highstate.timer`.) If you already trigger highstates another way,
  point that existing mechanism at the returner/wrapper instead of running
  a second, independent highstate schedule.
- `SALT_STUCK_JOB_THRESHOLD` / `SALT_HUNG_RUN_THRESHOLD` env vars at the top
  of `salt_check.sh` — how long a job or highstate run can run before being
  flagged as stuck (defaults 30min / 60min).
- Both scripts default to `salt-call --local ...` (masterless-style
  execution against the minion's own config/cache). If this minion is
  master-managed and you'd rather the highstate go through the normal
  master-driven path, drop `--local` from both scripts.

## Notes / limitations

- The ping check exercises the minion's local Python/state execution
  engine (via a fresh `salt-call` subprocess), not literally the running
  daemon's event-bus thread. In practice this catches the common "minion
  process exists but can't actually execute states" failure mode. If you
  need to verify live master-transport connectivity specifically, that's
  better checked from the Salt master (`salt-run manage.status`) than from
  the minion itself.
- Zabbix numeric items are unsigned only; `salt.highstate.age` uses a large
  sentinel value (999999999) when no highstate has ever been recorded, so
  the staleness trigger fires correctly on a fresh host rather than trying
  to represent "-1."
