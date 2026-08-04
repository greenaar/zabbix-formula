{% from "zabbix/map.jinja" import zabbix with context -%}

include:
  - zabbix.users

{%- set srv_user = zabbix | traverse('server:srv_user', zabbix.user) %}
{%- set srv_group = zabbix | traverse('server:srv_group', zabbix.group) %}

zabbix-server:
  pkg.installed:
    - pkgs:
      {%- for name in zabbix.server.pkgs %}
      - {{ name }}{% if zabbix.server.version is defined and 'zabbix' in name %}: '{{ zabbix.server.version }}'{% endif %}
      {%- endfor %}
    {% if salt['grains.get']('os_family') == 'Debian' -%}
    - install_recommends: False
    {% endif %}
    - require_in:
      - user: zabbix-formula_zabbix_user
      - group: zabbix-formula_zabbix_group
  service.running:
    - name: {{ zabbix.server.service }}
    - enable: True
    - require:
      - pkg: zabbix-server
      - file: zabbix-server-logdir
      - file: zabbix-server-piddir

zabbix-web-service:
  service.running:
    - name: {{ zabbix.server.webservice }}
    - enable: True
    - require:
      - pkg: zabbix-server

zabbix-server-logdir:
  file.directory:
    - name: {{ salt['file.dirname'](zabbix.server.logfile) }}
    - user: {{ srv_user }}
    - group: {{ srv_group }}
    - dirmode: 755
    - require:
      - pkg: zabbix-server

zabbix-server-piddir:
  file.directory:
    - name: {{ salt['file.dirname'](zabbix.server.pidfile) }}
    - user: {{ srv_user }}
    - group: {{ srv_group }}
    - dirmode: 755
    - require:
      - pkg: zabbix-server

