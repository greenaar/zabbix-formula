{% from "zabbix/map.jinja" import zabbix with context -%}

include:
  - zabbix.frontend

# We have a common template for the official Zabbix repo
{% include "zabbix/repo.sls" %}

# Here we just add a requisite declaration to ensure correct order
extend:
  zabbix_frontend_repo:
    pkgrepo:
      - require_in:
        - pkg: zabbix-frontend-php
