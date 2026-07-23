# Acumatica DevOps SPEC

## §G GOAL

MailPilot systemd unit settles durable failed/non-active on schema-gate or config-class exit 1 (not infinite `Restart=on-failure` green loop); deploy path ! run `mailpilot db migrate` + `db check` before unit restart. Closes #2.

## §C CONSTRAINTS

- localhost trust lines unchanged (`local`, `127.0.0.1/32`, `::1/128`)
- Tailscale `100.64.0.0/10` scram-sha-256 line stays
- VM-subnet CIDR from inventory var (`vm_subnet`), not hard-coded CIDR in role task when lab subnet can change
- role re-run idempotent — not drop other intended hba lines
- password for role `pilot` remains kronos root file `/root/mailpilot-pg-remote-<host>.pass`
- primary fix = migrate-before-restart; unit policy = secondary operator signal
- app already exits 1 w/ `schema_migration_pending` envelope — no mailpilot app change required here
- unit policy among `RestartPreventExitStatus` / `StartLimitBurst`+`Interval` / `Restart=` change — document next to template

## §I INTERFACES

- role: `mailpilot_postgresql` → writes `/etc/postgresql/18/main/pg_hba.conf`, creates `pilot`/`reporter`
- cmd: `gmake mailpilot-postgresql LIMIT=<guest>` → ansible tag `mailpilot_postgresql` (reload/restart via notify)
- var: `vm_subnet` (`ansible/group_vars/all.yml`, default `192.168.122.0/24`) → pg_hba host ADDRESS
- file: kronos `/root/mailpilot-pg-remote-<host>.pass` → remote user `pilot` password
- docs: `docs/mailpilot.md` → remote DB URL pattern + password fetch + unit restart policy
- unit: `ansible/roles/mailpilot_crm/templates/mailpilot.service.j2` → systemd `mailpilot.service`
- role: `mailpilot_crm` → install + db init/migrate/check + unit install
- cmd: `gmake mailpilot-release` → package upgrade + schema migrate/check + unit restart

## §V INVARIANTS

V1: lab-db-reachability — every documented remote client path for MailPilot Postgres ! matching `pg_hba` host line (first principle)
V2: localhost trust preserved — `local` + `127.0.0.1/32` + `::1/128` trust lines present after role
V3: tailscale-hba — `host all all 100.64.0.0/10 scram-sha-256` present after role
V4: vm-subnet-hba — `host all all <vm_subnet> scram-sha-256` present; ADDRESS from `vm_subnet` (or role default derived from it)
V5: hba-idempotent — re-run `mailpilot_postgresql` not drop intended hba lines
V6: docs-remote-db — `docs/mailpilot.md` notes VM-subnet pg_hba allow + how to fetch `pilot` password from kronos
V7: schema-gate-unit-signal — schema-gate/config-class process exit ! leave unit long-term Active: active (running) while agent dead; unit reaches stable non-active/failed operators can alert on w/o manual stop
V8: migrate-before-restart — deploy/upgrade path ! run `mailpilot db migrate` (+ preferably `db check`) before restarting mailpilot.service
V9: unit-policy-docs — chosen Restart/StartLimit/RestartPreventExitStatus policy documented next to unit template or in docs/mailpilot.md unit section
V10: schema-gate-probe — lab or CI: start unit against pending-schema DB → status not green crash-loop

## §T TASKS

id|status|task|cites
T1|x|add pg_hba host line for `vm_subnet` (scram-sha-256) via role var in `mailpilot_postgresql` install.yml|V1,V4,I.role,I.var
T2|x|document remote DB URL pattern (guest IP / `*.vm.internal`) + `pilot` password path in docs/mailpilot.md|V6,I.docs,I.file
T3|x|confirm `gmake mailpilot-postgresql LIMIT=mailpilot-1` applies hba + reloads Postgres; accept from control machine w/ `database_url` @ guest IP|V1,V2,V3,V5,I.cmd
T4|x|harden mailpilot.service.j2 so schema-gate exit 1 not infinite Restart=on-failure loop (StartLimitBurst/Interval and/or RestartPreventExitStatus; document choice)|V7,V9,I.unit
T5|.|ensure mailpilot_crm deploy runs db init → migrate → check before unit restart (primary path)|V8,I.role,I.cmd
T6|.|document unit restart policy next to template / docs/mailpilot.md|V9,I.unit,I.docs
T7|.|lab or CI probe: pending schema → unit not green crash-loop|V7,V10

## §B BUGS

id|date|cause|fix
