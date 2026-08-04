{% from "zabbix/map.jinja" import zabbix with context -%}
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

{% set dbuser_host = settings.get('dbuser_host', defaults.dbuser_host) -%}
{# Administrative connections inherit the shared mysql formula contract. #}
{% set shared_mysql = salt['pillar.get']('mysql', {}) -%}
{% set shared_connection = shared_mysql.get('connection', {}) -%}
{% set connection = settings.get('connection', shared_connection) -%}
{% set use_socket = connection.get('method', 'socket') == 'socket' -%}
{% set dbsocket = connection.get('unix_socket', '/run/mysqld/mysqld.sock') -%}
{% set admin_host = connection.get('host', dbhost) -%}
{% set admin_port = connection.get('port', 3306) -%}
{% set dbroot_user = settings.get('dbroot_user') or shared_mysql.get('salt_user', {}).get('salt_user_name') or shared_mysql.get('server', {}).get('root_user', 'root') -%}
{% set dbroot_pass = settings.get('dbroot_pass') or shared_mysql.get('salt_user', {}).get('salt_user_password') or shared_mysql.get('server', {}).get('root_password') -%}

# Install Zabbix's SQL assets. The shared mysql formula installs saltext-mysql
# into Salt's onedir Python runtime; an OS python3-mysqldb package cannot do so.
{% if settings.get('pkgs', defaults.get('pkgs', False))
      and not settings.get('skip_pkgs', defaults.skip_pkgs) -%}
mysql_packages:
  pkg.installed:
    - pkgs: {{ settings.get('pkgs', defaults.pkgs)|json }}
{% elif settings.get('skip_pkgs', defaults.skip_pkgs) -%}
mysql_packages:
  test.configurable_test_state:
    - name: You skipped installation of the Zabbix MySQL support packages.
    - changes: False
    - result: True
{% else -%}
mysql_packages:
  test.configurable_test_state:
    - name: Zabbix MySQL support packages are not defined
    - changes: False
    - result: False
    - comment: |
        The Zabbix SQL scripts package is required for schema initialization.
        Please specify them in pillar as list.
        zabbix-mysql:
          pkgs:
            - zabbix-sql-scripts
        Or you can skip installing them.
        zabbix-mysql:
          skip_pkgs: True
{% endif -%}

zabbix_db:
  mysql_database.present:
    - name: {{ dbname }}
    - host: {{ dbhost }}
    {%- if use_socket %}
    - connection_unix_socket: '{{ dbsocket }}'
    {%- else %}
    - connection_host: '{{ admin_host }}'
    - connection_port: {{ admin_port }}
    {%- endif %}
    {%- if dbroot_user %}
    - connection_user: {{ dbroot_user }}
    {%- endif %}
    {%- if dbroot_pass %}
    - connection_pass: '{{ dbroot_pass }}'
    {%- endif %}
    - character_set: utf8mb4
    - collate: utf8mb4_bin
    - require:
      - mysql_packages
      - service: mysql-service
  mysql_user.present:
    - name: {{ dbuser }}
    - host: '{{ dbuser_host }}'
    - password: '{{ dbpassword }}'
    {%- if use_socket %}
    - connection_unix_socket: '{{ dbsocket }}'
    {%- else %}
    - connection_host: '{{ admin_host }}'
    - connection_port: {{ admin_port }}
    {%- endif %}
    {%- if dbroot_user %}
    - connection_user: {{ dbroot_user }}
    {%- endif %}
    {%- if dbroot_pass %}
    - connection_pass: '{{ dbroot_pass }}'
    {%- endif %}
    - require:
      - mysql_packages
      - service: mysql-service
  mysql_grants.present:
    - grant: all privileges
    - database: {{ dbname }}.*
    - user: {{ dbuser }}
    - host: '{{ dbuser_host }}'
    {%- if use_socket %}
    - connection_unix_socket: '{{ dbsocket }}'
    {%- else %}
    - connection_host: '{{ admin_host }}'
    - connection_port: {{ admin_port }}
    {%- endif %}
    {%- if dbroot_user %}
    - connection_user: {{ dbroot_user }}
    {%- endif %}
    {%- if dbroot_pass %}
    - connection_pass: '{{ dbroot_pass }}'
    {%- endif %}
    - require:
      - mysql_packages
      - service: mysql-service
      - mysql_database: zabbix_db
      - mysql_user: zabbix_db
