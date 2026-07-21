# Acumatica DevOps SPEC

## §G GOAL

MailPilot Postgres on lab guests accepts remote clients over `vm_subnet` (libvirt NAT / kronos gateway) w/ scram-sha-256 — same path operators use for SSH/CLI. Closes #1.

## §C CONSTRAINTS

- localhost trust lines unchanged (`local`, `127.0.0.1/32`, `::1/128`)
- Tailscale `100.64.0.0/10` scram-sha-256 line stays
- VM-subnet CIDR from inventory var (`vm_subnet`), not hard-coded CIDR in role task when lab subnet can change
- role re-run idempotent — not drop other intended hba lines
- password for role `pilot` remains kronos root file `/root/mailpilot-pg-remote-<host>.pass`

## §I INTERFACES

- role: `mailpilot_postgresql` → writes `/etc/postgresql/18/main/pg_hba.conf`, creates `pilot`/`reporter`
- cmd: `gmake mailpilot-postgresql LIMIT=<guest>` → ansible tag `mailpilot_postgresql` (reload/restart via notify)
- var: `vm_subnet` (`ansible/group_vars/all.yml`, default `192.168.122.0/24`) → pg_hba host ADDRESS
- file: kronos `/root/mailpilot-pg-remote-<host>.pass` → remote user `pilot` password
- docs: `docs/mailpilot.md` → remote DB URL pattern + password fetch

## §V INVARIANTS

V1: lab-db-reachability — every documented remote client path for MailPilot Postgres ! matching `pg_hba` host line (first principle)
V2: localhost trust preserved — `local` + `127.0.0.1/32` + `::1/128` trust lines present after role
V3: tailscale-hba — `host all all 100.64.0.0/10 scram-sha-256` present after role
V4: vm-subnet-hba — `host all all <vm_subnet> scram-sha-256` present; ADDRESS from `vm_subnet` (or role default derived from it)
V5: hba-idempotent — re-run `mailpilot_postgresql` not drop intended hba lines
V6: docs-remote-db — `docs/mailpilot.md` notes VM-subnet pg_hba allow + how to fetch `pilot` password from kronos

## §T TASKS

id|status|task|cites
T1|x|add pg_hba host line for `vm_subnet` (scram-sha-256) via role var in `mailpilot_postgresql` install.yml|V1,V4,I.role,I.var
T2|x|document remote DB URL pattern (guest IP / `*.vm.internal`) + `pilot` password path in docs/mailpilot.md|V6,I.docs,I.file
T3|.|confirm `gmake mailpilot-postgresql LIMIT=mailpilot-1` applies hba + reloads Postgres; accept from control machine w/ `database_url` @ guest IP|V1,V2,V3,V5,I.cmd

## §B BUGS

id|date|cause|fix
