{% from "zabbix/map.jinja" import zabbix with context -%}
{% from "zabbix/libtofs.jinja" import files_switch with context -%}
{% set settings = salt['pillar.get']('zabbix-mysql', {}) -%}
{% set defaults = zabbix.get('mysql', {}) -%}
# This required for backward compatibility
{% if 'dbpass' in settings -%}
{%  do settings.update({'dbpassword': settings['dbpass']}) -%}
{% endif -%}

{% set dbhost = settings.get('dbhost', defaults.dbhost) -%}
{% set dbname = settings.get('dbname', defaults.dbname) -%}
{% set dbuser = settings.get('dbuser', defaults.dbuser) -%}
{% set dbpassword = settings.get('dbpassword', defaults.dbpassword) -%}

{% set shared_mysql = salt['pillar.get']('mysql', {}) -%}
{% set shared_connection = shared_mysql.get('connection', {}) -%}
{% set connection = settings.get('connection', shared_connection) -%}
{% set use_socket = connection.get('method', 'socket') == 'socket' -%}
{% set dbsocket = connection.get('unix_socket', '/run/mysqld/mysqld.sock') -%}
{% set admin_host = connection.get('host', dbhost) -%}
{% set admin_port = connection.get('port', 3306) -%}
{% set cli_connection = '--socket=' ~ dbsocket if use_socket else '--host=' ~ admin_host ~ ' --port=' ~ admin_port -%}

{# Since Zabbix 6.4, the zabbix-sql-scripts package (already in
   zabbix.mysql.pkgs) ships the schema at a fixed, version-independent path
   instead of a version-suffixed one - the OS package itself always matches
   whatever Zabbix release is installed. So there's no need to vendor our own
   copy of the schema by default; only fall back to a TOFS-managed file if
   the caller explicitly points `sql_file` at something else (e.g. an
   air-gapped install). #}
{% set sql_file = settings.get('sql_file', '/usr/share/zabbix-sql-scripts/mysql/server.sql.gz') -%}

include:
  - zabbix.mysql.conf

{% if 'sql_file' in settings -%}
{{ sql_file }}:
  file.managed:
    - makedirs: True
    - source: {{ files_switch([sql_file],
                              lookup='zabbix-server-mysql'
                 )
              }}
{% endif -%}

{# mysql_query.run_file (the Salt MySQL state) struggles with a schema file
   this large and can't transparently decompress the packaged .gz, so shell
   out to the mysql client instead - same approach already used for
   pgsql/schema.sls. `set -o pipefail` makes sure a failing import is
   reported as a failure instead of being masked by the last command in the
   pipe. #}
import_sql:
  cmd.run:
    - name: >-
        set -o pipefail;
        {% if sql_file.endswith('.gz') -%}
        zcat {{ sql_file }} | mysql {{ cli_connection }} --user={{ dbuser }} --database={{ dbname }} --default-character-set=utf8mb4
        {%- else -%}
        mysql {{ cli_connection }} --user={{ dbuser }} --database={{ dbname }} --default-character-set=utf8mb4 < {{ sql_file }}
        {%- endif %}
    - shell: /bin/bash
    - env:
      - MYSQL_PWD: '{{ dbpassword }}'
    - require:
      - mysql_packages
      - service: mysql-service
      - mysql_database: zabbix_db
      - mysql_user: zabbix_db
      {%- if 'sql_file' in settings %}
      - file: {{ sql_file }}
      {%- endif %}
    - unless: >-
        mysql {{ cli_connection }} --user={{ dbuser }} --database={{ dbname }}
        --batch --skip-column-names -e "SHOW TABLES LIKE 'users'" | grep -Fqx users
