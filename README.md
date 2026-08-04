# zabbix-formula

A SaltStack formula for installing and configuring Zabbix 7.4: agent2, server,
proxy, web frontend, and the MySQL/PostgreSQL backend for the server.

> This formula targets **Zabbix 7.4 only**. Repo URLs, GPG keys, and config
> templates assume the 7.4 package layout. Older versions are not supported.

## Table of contents

- [Availability](#availability)
- [Formula layout](#formula-layout)
- [Pillar namespaces](#pillar-namespaces)
- [Quickstart](#quickstart)
- [State documentation](#state-documentation)
  - [`zabbix.agent`](#zabbixagent)
  - [`zabbix.server`](#zabbixserver)
  - [`zabbix.proxy`](#zabbixproxy)
  - [`zabbix.frontend`](#zabbixfrontend)
  - [`zabbix.mysql`](#zabbixmysql)
  - [`zabbix.pgsql`](#zabbixpgsql)
  - [`zabbix.users`](#zabbixusers)
- [Adding checks to the agent](#adding-checks-to-the-agent)
  - [1. UserParameter (simplest)](#1-userparameter-simplest)
  - [2. UserParameter with flexible parameters](#2-userparameter-with-flexible-parameters)
  - [3. Dropping files via `Include`](#3-dropping-files-via-include)
  - [4. Managing check scripts with Salt (TOFS)](#4-managing-check-scripts-with-salt-tofs)
  - [5. Loadable/native plugins](#5-loadablenative-plugins)
  - [6. UnsafeUserParameters / AllowKey / DenyKey](#6-unsafeuserparameters--allowkey--denykey)
  - [Reloading the agent after adding a check](#reloading-the-agent-after-adding-a-check)
- [TOFS (Template Override and Files Switch)](#tofs-template-override-and-files-switch)
- [Supported OS families](#supported-os-families)
- [Testing](#testing)

## Availability

This refactor targets current Debian and Ubuntu releases only. Other operating
systems are intentionally rejected by the repository state.

## Formula layout

```
zabbix/
├── agent/            # zabbix-agent2
│   ├── init.sls       # package + service
│   ├── repo.sls        # official Zabbix repo
│   └── conf.sls        # zabbix_agent2.conf
├── server/           # zabbix-server
│   ├── init.sls
│   ├── repo.sls
│   └── conf.sls
├── proxy/            # zabbix-proxy
│   ├── init.sls
│   ├── repo.sls
│   └── conf.sls
├── frontend/         # zabbix-web (PHP frontend)
│   ├── init.sls
│   ├── repo.sls
│   └── conf.sls
├── mysql/            # MySQL backend for zabbix-server
│   ├── conf.sls        # DB + user + grants
│   └── schema.sls       # imports the Zabbix SQL schema
├── pgsql/            # PostgreSQL backend for zabbix-server
│   ├── pkgs.sls
│   ├── conf.sls
│   └── schema.sls
├── users.sls          # zabbix system user/group
├── debconf.sls        # silences Debian package prompts
├── repo.sls            # shared Zabbix official-repo logic (included by *.repo.sls)
├── map.jinja           # merges defaults.yaml + os*map.yaml + pillar
├── libtofs.jinja        # TOFS `files_switch` macro
├── defaults.yaml        # baseline formula-level settings
├── osfamilymap.yaml     # overrides by grains['os_family']
├── osmap.yaml            # overrides by grains['os']
├── osfingermap.yaml      # overrides by grains['osfinger']
└── files/default/...    # default Jinja templates (zabbix_agent2.conf, etc.)
```

Each service directory follows the same three-file pattern:

| file        | purpose                                              |
|-------------|-------------------------------------------------------|
| `init.sls`  | installs the package(s) and manages the service      |
| `repo.sls`  | adds the official Zabbix package repository           |
| `conf.sls`  | renders the config file from a Jinja template (TOFS)  |

There's no top-level `init.sls` that pulls everything in — include exactly
the pieces you need per host, e.g. `zabbix.agent`, `zabbix.agent.repo`,
`zabbix.agent.conf`, `zabbix.server`, `zabbix.server.repo`, `zabbix.server.conf`,
`zabbix.mysql.schema`, etc.

## Pillar namespaces

This formula reads **two different kinds of pillar data**, and it's the
single most common point of confusion, so it's worth being explicit:

1. **`zabbix:`** — formula-level settings (package names, versions, service
   names, file paths, the repo version to track, the system user/group).
   This is merged into `map.jinja`'s `zabbix` variable together with
   `defaults.yaml` and the `os*map.yaml` files, following the grain
   precedence: `defaults.yaml` → `osfamilymap.yaml` → `osmap.yaml` →
   `osfingermap.yaml` → your `zabbix:` pillar (pillar always wins).

2. **`zabbix-agent:` / `zabbix-server:` / `zabbix-proxy:` / `zabbix-frontend:`
   / `zabbix-mysql:` / `zabbix-pgsql:`** — the actual *runtime configuration*
   for each daemon/component, i.e. the values that get written into
   `zabbix_agent2.conf`, `zabbix_server.conf`, etc. These are read directly
   with `pillar.get('zabbix-agent', {})` and are **not** merged through
   `map.jinja` — anything you don't set here falls back to the matching key
   under `zabbix.agent` / `zabbix.server` / ... in the `zabbix:` namespace.

In short: `zabbix:` = "how to install it", `zabbix-agent:` (etc.) = "how to
configure it once it's installed".

## Quickstart

This formula has no default state: agent, server, proxy, and frontend are
separate roles, so you pick them per host. `state.apply zabbix` exists only
to fail with a message listing the available roles, rather than erroring
out with "No matching sls found".

```yaml
# top.sls
base:
  'zabbix-server*':
    - zabbix.users
    - zabbix.server.repo
    - zabbix.server
    - zabbix.server.conf
    - zabbix.mysql.conf
    - zabbix.mysql.schema
    - zabbix.frontend.repo
    - zabbix.frontend
    - zabbix.frontend.conf

  '*':
    - zabbix.agent.repo
    - zabbix.agent
    - zabbix.agent.conf
```

Apply with:

```bash
salt 'zabbix-server*' state.apply
salt '*' state.apply
```

See `pillar.example` in this folder for a complete, heavily-commented
pillar covering server, proxy, agent, MySQL, and PostgreSQL.

## State documentation

### `zabbix.agent`

- `zabbix.agent` — installs `zabbix.agent.pkgs` (default: `zabbix-agent2`,
  `zabbix-sender`), creates the log/pid directories, manages the
  `zabbix-agent2` service, and creates any directories listed under
  `includes` (see [Adding checks](#adding-checks-to-the-agent)).
- `zabbix.agent.repo` — adds the official Zabbix repository.
- `zabbix.agent.conf` — renders `/etc/zabbix/zabbix_agent2.conf` from
  `files/default/etc/zabbix/zabbix_agent2.conf.jinja` and triggers an agent
  restart when it changes.

Relevant pillar: `zabbix-agent:` (see full option list by reading
`files/default/etc/zabbix/zabbix_agent2.conf.jinja` — every commented
option in that file maps 1:1 to a lowercase pillar key).

### `zabbix.server`

Installs `zabbix-server-mysql` (or the PostgreSQL equivalent, if you swap the
`pkgs` list) plus `zabbix-web-service`, manages the `zabbix-server` and
`zabbix-web-service` services, and (`.conf`) renders `zabbix_server.conf`
from pillar key `zabbix-server:`. On Debian it also predefines debconf
answers so the package doesn't try to auto-configure the database for you.

### `zabbix.proxy`

Same pattern as the server, for `zabbix-proxy`. Supports SQLite (default,
`dbname` is a file path and the formula creates that directory for you) or
an external MySQL/PostgreSQL database if you point `zabbix.proxy.pkgs` at
`zabbix-proxy-mysql` / `zabbix-proxy-pgsql` and set `dbhost`/`dbname`/etc.
under pillar key `zabbix-proxy:` accordingly.

### `zabbix.frontend`

Installs the PHP frontend package(s), sets the two SELinux booleans it needs
when SELinux is enforcing, and (`.conf`) renders
`/etc/zabbix/web/zabbix.conf.php` from pillar key `zabbix-frontend:`. This
formula does **not** manage Apache/Nginx or PHP-FPM themselves — bring your
own webserver formula and point its vhost at
`/usr/share/zabbix` (or wherever your package installs the frontend files).

### `zabbix.mysql`

- `zabbix.mysql.conf` — creates the `zabbix` database, DB user, and grants.
  The included `roles.zabbix_server` state composes this with the shared
  `mysql` formula, which installs `saltext-mysql` into Salt's onedir runtime
  and provides socket/TCP administration settings. `zabbix.mysql.pkgs`
  defaults to `zabbix-sql-scripts`; use
  `zabbix-mysql: {skip_pkgs: true}` only when those schema assets are managed
  elsewhere.
- `zabbix.mysql.schema` — imports `/usr/share/zabbix-sql-scripts/mysql/server.sql.gz`
  (shipped by the `zabbix-sql-scripts` package since 6.4) the first time the
  database is empty. Override `sql_file` under `zabbix-mysql:` to import a
  custom/offline dump via TOFS instead.

### `zabbix.pgsql`

Same idea as `mysql`, using `postgres_user`/`postgres_database` and importing
`/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz`.

### `zabbix.users`

Creates the `zabbix` system user/group used by every other state. Add extra
group memberships (e.g. `docker`, to let the agent poll the Docker socket)
via `zabbix:user_groups` in pillar.

## Adding checks to the agent

Zabbix agent2 supports several ways to add custom checks. Pick the one that
fits, in order of how simple it is to manage from Salt.

### 1. UserParameter (simplest)

Add entries to the `userparameters` list under the `zabbix-agent:` pillar
key. Each entry is the full `key,command` string exactly as it would appear
in the config file:

```yaml
zabbix-agent:
  userparameters:
    - 'mysql.ping,mysqladmin ping 2>&1'
    - 'app.queue.depth,/usr/local/bin/queue_depth.sh'
    - 'vfs.file.count.tmp,find /tmp -type f | wc -l'
```

The `conf.sls` template writes one `UserParameter=<key>,<command>` line per
entry directly into `zabbix_agent2.conf`, so these checks are live as soon
as the config state runs and the agent restarts (the state already
`watch_in`s a `module.wait` restart of the service — no extra state needed).

Use this for one-off, host-specific checks that don't warrant their own
script file.

### 2. UserParameter with flexible parameters

Same mechanism, just include `[*]` in the key so Zabbix can pass
arguments from the item configuration on the server side:

```yaml
zabbix-agent:
  userparameters:
    - 'app.http.check[*],curl -s -o /dev/null -w "%{http_code}" http://localhost:$1$2'
    - 'custom.service.status[*],systemctl is-active $1 2>&1'
```

On the server/frontend, create items like `app.http.check[:8080/health]` or
`custom.service.status[nginx]`.

### 3. Dropping files via `Include`

If you have several UserParameters, or want them grouped per-application,
write them to a dedicated file instead of inlining every line in
`zabbix_agent2.conf`. The formula already creates any directory you list
under `includes`:

```yaml
zabbix-agent:
  includes:
    - /etc/zabbix/zabbix_agent2.d/
```

That produces `Include=/etc/zabbix/zabbix_agent2.d/` in the config (a
trailing slash means "load every file in this directory"). You then need a
state of your own (in your own formula/pillar, or appended to this one via
an `extend:`) to drop actual `.conf` files into that directory, e.g.:

```yaml
# in your own sls file
/etc/zabbix/zabbix_agent2.d/mysql.conf:
  file.managed:
    - contents: |
        UserParameter=mysql.ping,mysqladmin ping 2>&1
        UserParameter=mysql.status[*],mysqladmin -sLuzabbix status | cut -d" " -f$1
    - user: root
    - group: zabbix
    - mode: '0640'
    - require:
      - pkg: zabbix-agent
    - watch_in:
      - module: zabbix-agent-restart
```

This scales much better than the flat `userparameters` list once you have
more than a handful of checks, and it lets you version/organize checks per
application rather than as one big pillar list.

### 4. Managing check scripts with Salt (TOFS)

If your UserParameter calls out to a script (rather than an inline shell
one-liner), ship the script itself with Salt using the same TOFS pattern
the formula already uses for config files, so it benefits from the same
per-minion/per-os_family override lookup:

```yaml
/usr/local/bin/queue_depth.sh:
  file.managed:
    - source: salt://zabbix/files/default/usr/local/bin/queue_depth.sh
    - user: root
    - group: root
    - mode: '0755'
    - require_in:
      - file: {{ zabbix.agent.config }}
```

Then reference `/usr/local/bin/queue_depth.sh` from a `userparameters` entry
or an includes-file entry as above. Put the script under
`zabbix/files/default/usr/local/bin/` (or the OS-specific TOFS subfolder,
e.g. `zabbix/files/Debian/...`) to mirror how `zabbix_agent2.conf.jinja`
itself is organized.

### 5. Loadable/native plugins

Zabbix agent2 also ships and auto-loads binary/Go plugins (Docker, Redis,
Memcached, Postgres, MySQL, etc.) that are configured with
`Plugins.<Name>.<Option>=<value>` lines rather than `UserParameter`. The
config template already appends:

```
Include=./zabbix_agent2.d/plugins.d/*.conf
```

so drop plugin config into `/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf`
the same way as in option 3 above, e.g.:

```yaml
/etc/zabbix/zabbix_agent2.d/plugins.d/mysql.conf:
  file.managed:
    - contents: |
        Plugins.Mysql.Sessions.myconn.Uri=tcp://localhost:3306
        Plugins.Mysql.Sessions.myconn.User=zbx_monitor
        Plugins.Mysql.Sessions.myconn.Password=secret
    - mode: '0640'
    - user: root
    - group: zabbix
    - require:
      - pkg: zabbix-agent
    - watch_in:
      - module: zabbix-agent-restart
```

Prefer native plugins over `system.run`-based UserParameters when one exists
for what you're monitoring — they're faster, don't spawn a shell per check,
and support Zabbix's built-in discovery/preprocessing better.

### 6. UnsafeUserParameters / AllowKey / DenyKey

- If a UserParameter command needs shell metacharacters
  (`` \ ' " ` * ? [ ] { } ~ $ ! & ; ( ) < > | # @ `` or newlines) passed
  through from item parameters, set:

  ```yaml
  zabbix-agent:
    unsafeuserparameters: 1
  ```

- `system.run[*]` (arbitrary remote command execution) is denied by default
  by Zabbix agent2 itself unless you explicitly allow it. If you rely on it,
  add an explicit `allowkey`, e.g.:

  ```yaml
  zabbix-agent:
    allowkey: 'system.run[*]'
  ```

  Only do this if you understand the security implications — anyone able to
  create items on the Zabbix server for this host can then run arbitrary
  shell commands as the agent user (or root, if `AllowRoot=1`).

### Reloading the agent after adding a check

You don't need to do anything extra: `zabbix.agent.conf` already declares

```yaml
{{ zabbix.agent.config }}:
  file.managed:
    ...
    - watch_in:
      - module: zabbix-agent-restart
```

so any change to `zabbix_agent2.conf` (including a changed `UserParameter=`
line) triggers `zabbix-agent-restart` automatically. If you add a check via
an `Include`-d file instead (options 3–5 above), make sure *that* state also
has `watch_in: [module: zabbix-agent-restart]`, since it's a separate file
outside the one the built-in state watches.

After applying, verify from the minion:

```bash
zabbix_agent2 -t mysql.ping         # test a single key locally
zabbix_agent2 -p                    # print all supported/known keys
```

## TOFS (Template Override and Files Switch)

Every `conf.sls` (and the mysql/pgsql `schema.sls`) resolves its `source:`
through the `files_switch` macro in `libtofs.jinja`. That means you can
override any shipped template on a per-minion or per-`os_family` basis
without touching the formula, by dropping a file at:

```
salt://zabbix/files/<minion_id>/etc/zabbix/zabbix_agent2.conf.jinja
salt://zabbix/files/<os_family>/etc/zabbix/zabbix_agent2.conf.jinja
salt://zabbix/files/default/etc/zabbix/zabbix_agent2.conf.jinja   # shipped default
```

Lookup order is minion id → `os_family` → `default`, most specific first.
This is the same mechanism used by all `saltstack-formulas`-style formulas.

## Supported OS families

| Platform | Releases represented in the map | Server/database support |
|----------|---------------------------------|-------------------------|
| Debian   | 12, 13                          | MySQL and PostgreSQL    |
| Ubuntu   | 22.04, 24.04                    | MySQL and PostgreSQL    |

## Testing

This formula follows the common `saltstack-formulas` layout, so if you have
kitchen-salt/pytest-salt-factories tests set up elsewhere in your pipeline,
point them at the `tests/` directory you add for your environment — none is
bundled in this archive.

## Relationship to upstream

**This is a heavily modified fork of
[`saltstack-formulas/zabbix-formula`](https://github.com/saltstack-formulas/zabbix-formula). Do not treat it as a drop-in
replacement for it.**

States have been renamed, split, merged, and removed; pillar keys have moved;
defaults differ; and behaviour has changed in ways that are not backward
compatible. Pointing an existing deployment at this formula without reading
`pillar.example` and the state list above will not do what you expect.

It is also not a newer version of upstream — it diverged and was maintained
separately, so upstream may well have fixes and platform support that this
does not. If you want the maintained original, use
[`saltstack-formulas/zabbix-formula`](https://github.com/saltstack-formulas/zabbix-formula).

### Credit

The foundation of this formula, and much of what still works well in it, is
the work of the [saltstack-formulas](https://github.com/saltstack-formulas) authors and contributors. Any
bugs introduced in the divergence are this fork's own.

Specific third-party files bundled here, with their own authors and
licenses, are itemised in [THIRD-PARTY.md](THIRD-PARTY.md).

## License

Dedicated to the public domain under [CC0 1.0 Universal](LICENSE), with the
exception of the third-party files listed in [THIRD-PARTY.md](THIRD-PARTY.md).
