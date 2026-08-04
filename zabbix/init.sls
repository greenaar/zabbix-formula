# -*- coding: utf-8 -*-
# vim: ft=sls
#
# There is deliberately no default state here.
#
# This formula covers the agent, the server, a proxy, and the web frontend,
# which are different roles on different hosts. Applying them all to every
# minion would be wrong, so pick the ones you want in your top file.
#
# This state exists only so that `state.apply zabbix` fails with an
# explanation instead of the bare "No matching sls found" a missing
# init.sls would produce.

zabbix-no-default-state:
  test.fail_without_changes:
    - name: >-
        The zabbix formula has no default state - choose a role instead.
        Agent:    zabbix.agent
        Server:   zabbix.server  (plus zabbix.mysql or zabbix.pgsql for the
                  database schema)
        Proxy:    zabbix.proxy
        Frontend: zabbix.frontend
        Also available: zabbix.repo, zabbix.users, zabbix.debconf.
        See the README.
    - failhard: True
