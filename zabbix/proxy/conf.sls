{% from "zabbix/map.jinja" import zabbix with context -%}
{% from "zabbix/libtofs.jinja" import files_switch with context -%}


include:
  - zabbix.proxy


{{ zabbix.proxy.config }}:
  file.managed:
    - source: {{ files_switch(['/etc/zabbix/zabbix_proxy.conf',
                               '/etc/zabbix/zabbix_proxy.conf.jinja'],
                              lookup='zabbix-proxy-config'
                 )
              }}
    - template: jinja
    - user: root
    - group: {{ zabbix.group }}
    - mode: '0640'
    - require:
      - pkg: zabbix-proxy
    - watch_in:
      - service: zabbix-proxy
