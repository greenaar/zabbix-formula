{% from "zabbix/map.jinja" import zabbix with context -%}
{% set settings = salt['pillar.get']('zabbix-agent', {}) -%}
{% set defaults = zabbix.get('agent', {}) -%}

{% if salt['grains.get']('os') != 'Windows' %}
include:
  - zabbix.users
{% endif %}

zabbix-agent:
  pkg.installed:
    - pkgs:
      {%- for name in zabbix.agent.pkgs %}
      - {{ name }}{% if zabbix.agent.version is defined and 'zabbix' in name %}: '{{ zabbix.agent.version }}'{% endif %}
      {%- endfor %}
{% if salt['grains.get']('os') != 'Windows' %}
    - require_in:
      - user: zabbix-formula_zabbix_user
      - group: zabbix-formula_zabbix_group
{% endif %}
  service.running:
    - name: {{ zabbix.agent.service }}
    - enable: True
    - require:
      - pkg: zabbix-agent
      - file: zabbix-agent-logdir
{% if salt['grains.get']('os') != 'Windows' %}
      - file: zabbix-agent-piddir
{% endif %}

zabbix-agent-restart:
  module.wait:
    - name: service.restart
    - m_name: {{ zabbix.agent.service }}

zabbix-agent-logdir:
  file.directory:
    - name: {{ salt['file.dirname'](zabbix.agent.logfile) }}
    - user: {{ zabbix.user }}
    - group: {{ zabbix.group }}
    - dirmode: 755
    - require:
      - pkg: zabbix-agent

{% if salt['grains.get']('os') != 'Windows' %}
zabbix-agent-piddir:
  file.directory:
    - name: {{ salt['file.dirname'](zabbix.agent.pidfile) }}
    - user: {{ zabbix.user }}
    - group: {{ zabbix.group }}
    - dirmode: 750
    - require:
      - pkg: zabbix-agent
{% endif %}

{% for include in settings.get('includes', defaults.get('includes', [])) %}
{{ include }}:
  file.directory:
    - name: {{ salt['file.dirname'](include) }}
    - user: {{ zabbix.user }}
    - group: {{ zabbix.group }}
    - dirmode: 750
    - require:
      - pkg: zabbix-agent
{%- endfor %}
