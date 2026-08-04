{% from "zabbix/map.jinja" import zabbix with context -%}

# Zabbix official repo releases a deb package that sets a zabbix.list apt
# sources. Here we do the same as that package does, including the PGP key for
# the repo.


# In order to share this state file among the different parts of Zabbix (agent,
# server, frontend, proxy) we have to name the states accordingly. See
# https://github.com/moreda/zabbix-saltstack-formula/issues/2 if you're curious.


{% if sls == "zabbix.agent.repo" %}{% set id_prefix = "zabbix_agent" -%}
{% elif sls == "zabbix.server.repo" %}{% set id_prefix = "zabbix_server" -%}
{% elif sls == "zabbix.frontend.repo" %}{% set id_prefix = "zabbix_frontend" -%}
{% elif sls == "zabbix.proxy.repo" %}{% set id_prefix = "zabbix_proxy" -%}
{% else %}{% set id_prefix = "zabbix" -%}
{% endif -%}

{# Zabbix moved every distro's packages under a "stable/" (or "release/" /
   "unstable/") subdirectory a while back. This formula only targets 7.4, so
   we always use the "stable/" layout below - there's no supported version
   of Zabbix left that still uses the old unversioned paths. #}

{% if salt['grains.get']('os_family') == 'Debian' -%}

{{ id_prefix }}_repo_dependencies:
  pkg.installed:
    - pkgs:
      - ca-certificates
      - gnupg

{{ id_prefix }}_repo_key:
  file.managed:
    - name: /etc/apt/keyrings/zabbix-official-repo.gpg
    - source: https://repo.zabbix.com/zabbix-official-repo-apr2024.gpg
    - source_hash: sha256=caf7a03592bb0ce970bc5e3632fefd42f4ad62684f4de5cdeaf7c83046e28c56
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: true
    - require:
      - pkg: {{ id_prefix }}_repo_dependencies

{{ id_prefix }}_repo:
  pkgrepo.managed:
    - name: deb [arch=amd64 signed-by=/etc/apt/keyrings/zabbix-official-repo.gpg] https://repo.zabbix.com/zabbix/{{ zabbix.version_repo }}/stable/{{ salt['grains.get']('os')|lower }} {{ salt['grains.get']('oscodename') }} main
    - file: /etc/apt/sources.list.d/zabbix.list
    - clean_file: true
    - aptkey: false
    - require:
      - file: {{ id_prefix }}_repo_key

{%- else %}
{{ id_prefix }}_repo:
  test.fail_without_changes:
    - name: The Zabbix formula supports Debian and Ubuntu only.
{%- endif %}
