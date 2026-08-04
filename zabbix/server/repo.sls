{% from "zabbix/map.jinja" import zabbix with context %}


include:
  - zabbix.server


# We have a common template for the official Zabbix repo
{% include "zabbix/repo.sls" %}


# Here we just add a requisite declaration to ensure correct order
extend:
  zabbix_server_repo:
    pkgrepo:
      - require_in:
        - pkg: zabbix-server
