{% from "zabbix/map.jinja" import zabbix with context -%}
{% from "zabbix/libtofs.jinja" import files_switch with context -%}
{% set settings = salt['pillar.get']('zabbix-pgsql', {}) -%}
{% set defaults = zabbix.get('pgsql', {}) -%}

{% set dbhost = settings.get('dbhost', defaults.dbhost) -%}
{% set dbname = settings.get('dbname', defaults.dbname) -%}
{% set dbuser = settings.get('dbuser', defaults.dbuser) -%}
{% set dbpassword = settings.get('dbpassword', defaults.dbpassword) -%}

{% set dbroot_user = settings.get('dbroot_user') -%}
{% set dbroot_pass = settings.get('dbroot_pass') -%}

{# Since Zabbix 6.4, the schema is shipped at this fixed, version-independent
   path by the zabbix-sql-scripts package rather than under
   /usr/share/doc/zabbix-server-pgsql/, and it no longer varies by release -
   so there's nothing to vendor here by default. Override `sql_file` in
   pillar to point at a custom dump instead (e.g. for an air-gapped install). #}
{% set sql_file = settings.get('sql_file', '/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz') -%}

# Connection args required only if dbroot_user and dbroot_pass defined.
{% set connection_args = {} -%}
{% if dbroot_user and dbroot_pass -%}
{%  set connection_args = {'runas': 'nobody', 'host': dbhost, 'user': dbroot_user, 'password': dbroot_pass} -%}
{% endif -%}

# Check is there any tables in database.
# salt.postgres.psql_query return empty result if there is no tables or 'False' on any error i.e. failed auth.
{% set list_tables = "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname != 'pg_catalog' AND schemaname != 'information_schema' LIMIT 1;" %}
{% set is_db_empty = True -%}
{% if salt.postgres.psql_query(query=list_tables, maintenance_db=dbname, **connection_args) -%}
{%  set is_db_empty = False -%}
{% endif -%}

include:
  - zabbix.pgsql.pkgs

check_db_pgsql:
  test.configurable_test_state:
    - name: Is there any tables in '{{ dbname }}' database?
    - changes: {{ is_db_empty }}
    - result: True
    - comment: If changes is 'True' data import required.

{% if 'sql_file' in settings -%}
upload_sql_dump:
  file.managed:
    - makedirs: True
    - source: {{ files_switch([sql_file],
                              lookup='zabbix-server-pgsql'
                 )
              }}
    - require_in:
      - import_sql
{% endif -%}

import_sql:
  cmd.run:
    # pipefail is required so a failing `psql` import isn't masked by the
    # exit status of `head` (a bare pipeline reports success/failure based
    # only on its last command). Only zcat when sql_file is actually
    # gzip-compressed, since a pillar-overridden sql_file may be plain SQL.
    - name: >-
        set -o pipefail;
        {% if sql_file.endswith('.gz') -%}
        zcat {{ sql_file }} | psql | head -5
        {%- else -%}
        psql < {{ sql_file }} | head -5
        {%- endif %}
    - shell: /bin/bash
    - runas: {{ zabbix.user }}
    - env:
      - PGUSER: {{ dbuser }}
      - PGPASSWORD: {{ dbpassword }}
      - PGDATABASE: {{ dbname }}
      - PGHOST: {{ dbhost }}
    - require:
      - pkg: zabbix-server
    - onchanges:
      - test: check_db_pgsql
