# Acumatica backup strategy

Two independent layers protect each Acumatica instance. Both are provisioned by
Ansible (the `mssql` and `storage` roles) and run unattended — nothing here is a
manual routine. `<host>` is the Ubuntu Linux host (substitute your `~/.ssh/config`
alias); all zvols live in pool `upool`.

| Layer | Scope | Consistency | Where it lives | Restores |
|-------|-------|-------------|----------------|----------|
| SQL-native `.bak` | Per user database | Application-consistent | Local `E:` disk + `\\<host>\mssql-backups` share | A single database, to any SQL Server |
| ZFS zvol snapshot | Whole VM (OS + data + backup disks) | Crash-consistent | Snapshots on `upool/vms` | The entire instance, in place |

Use the `.bak` layer for data integrity and portability; use zvol snapshots for
fast whole-VM "undo" of OS/app-level changes (bad Windows Update, botched
Acumatica upgrade). A zvol snapshot of a live SQL data disk is only
crash-consistent — equivalent to power-loss; SQL Server crash-recovers from it
via the log — so it is a rollback net, **not** the database backup of record.

## Nightly timeline

    02:00  SQL Agent job "Backup user databases" (in-guest, per instance)
    03:15  zfs-snap of the mssql-backups share dataset      (backup_snap_keep = 14)
    03:30  zfs-snap -r of upool/vms — every VM's zvols       (vm_snap_keep = 14)

The 02:00 job finishes well before the 03:15 share snapshot, so that snapshot
always captures a complete set of `.bak` files.

## Layer 1 — SQL-native backups

Provisioned by the `mssql` role (`--tags mssql_backup`). Each instance has a
dedicated **backup disk** — a third virtio zvol `upool/vms/<name>-backup`,
formatted `E:` — as the local backup target. The SQL Agent job **"Backup user
databases"** runs nightly at 02:00 (`mssql_backup_hour`) in two steps:

1. `BACKUP DATABASE` each online user DB (`database_id > 4`, not a snapshot) to
   `E:\sqlbackup\<db>.bak` `WITH INIT, COMPRESSION, CHECKSUM` — fast and
   application-consistent.
2. `backup-copy.cmd` robocopies those `.bak` files to
   `\\<host>\mssql-backups\<name>\`.

The share is dataset `upool/backups/mssql` (zstd-compressed), owned by the
Samba-only user `svc-backup` (password in `/root/svc-backup.smbpasswd` on the
host). The copy step authenticates with that credential via `net use` — it
can't be a plain `BACKUP TO DISK '\\...'` because the engine runs as the virtual
account `NT Service\MSSQLSERVER`, which reaches SMB as the *machine* account and
is rejected by the share's `valid users = svc-backup` (and `BACKUP TO DISK` has
no way to pass a credential). The credential is rendered into `backup-copy.cmd`
on the guest, never committed.

**Retention.** The local `E:` disk keeps only the latest dump per database
(`WITH INIT`). History lives on the share, snapshotted daily by
`/usr/local/sbin/zfs-snap` (03:15, `backup_snap_keep` = 14 kept) — so a prior
day's `.bak` is recoverable from `.zfs/snapshot/auto-*/` under the share mount.

**Run on demand** (e.g. before a risky change), from the guest:

    sqlcmd -E -Q "EXEC msdb.dbo.sp_start_job N'Backup user databases'"

**Restore a database:**

    RESTORE DATABASE AcumaticaDB
      FROM DISK = '\\<host>\mssql-backups\<name>\AcumaticaDB.bak'
      WITH REPLACE;

Recover an older copy by pointing `FROM DISK` at the share's
`.zfs/snapshot/auto-YYYYMMDD-HHMM/<name>/<db>.bak`.

## Layer 2 — ZFS zvol snapshots

Provisioned by the `storage` role. Each VM's disks are separate sibling zvols:

- `upool/vms/<name>` — OS disk (`C:`, a `zfs clone` of the golden image)
- `upool/vms/<name>-data` — SQL data disk (`D:`)
- `upool/vms/<name>-backup` — local `.bak` target (`E:`)

They are kept separate deliberately, so a `zfs rollback` of the OS disk never
drags the databases back with it.

The MailPilot guest zvols (`upool/vms/mailpilot-*` and `-data`) sit under the
same parent and are captured by the same recursive snapshot — for them it is
the only backup layer (see [mailpilot.md](mailpilot.md)).

A single daily cron entry takes **one atomic recursive snapshot** of the whole
parent:

    30 3 * * * root /usr/local/sbin/zfs-snap -r upool/vms 14

`zfs snapshot -r upool/vms@auto-…` captures every descendant zvol at the same
transaction group (so a VM's OS and data disks are mutually consistent), and
auto-includes any newly cloned VM. `zfs-snap` then prunes to the newest
`vm_snap_keep` (14) `auto-*` timestamps, recursively.

**Snapshot manually before a risky change**, and roll back:

    sudo zfs snapshot -r upool/vms/acu-dev1@before-upgrade    # or -data / whole VM
    # roll back — VM must be shut off first:
    sudo virsh shutdown acu-dev1
    sudo zfs rollback upool/vms/acu-dev1@before-upgrade

Named manual snapshots are not `auto-*`, so the nightly prune never touches
them.

## What this does not cover

This is a test/dev lab: **everything lives on the single `upool` pool on one
host.** Both layers survive a guest-level mistake (dropped DB, bad upgrade) and
a single-disk failure (ZFS redundancy, if the pool is a mirror/raidz), but a
total pool or host loss takes all of it. There is no off-host or off-site copy.

If that changes, `zfs-snap`'s `auto-*` snapshots are ready to feed `syncoid`
(replicate `upool/vms` and `upool/backups/mssql` to a second box) — that is the
point where a third-party manager like sanoid/syncoid would earn its keep. See
the [storage role](../ansible/roles/storage/) and README for why we don't run
one today.

## Configuration knobs

| Variable | Default | Where | Controls |
|----------|---------|-------|----------|
| `mssql_backup_hour` | `2` | `roles/mssql/defaults/main.yml` | SQL Agent job start hour |
| `mssql_backup_disk_size` | `50G` | `roles/mssql/defaults/main.yml` | Local `E:` backup zvol size (sparse) |
| `backup_snap_keep` | `14` | `group_vars/all.yml` | Daily snapshots kept of the backup share |
| `vm_snap_keep` | `14` | `group_vars/all.yml` | Daily recursive snapshots kept of `upool/vms` |

Snapshot schedules (03:15 / 03:30) are `cron.d` entries in
`roles/storage/tasks/main.yml`.
