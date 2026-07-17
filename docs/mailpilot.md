# MailPilot guests

One Ubuntu 26.04 guest per [MailPilot](https://github.com/kborovik/mailpilot)
instance on kronos, created from the Ubuntu cloud image (zvols + cloud-init) and
running `mailpilot-crm` from PyPI as the `mailpilot.service` systemd unit.
Ported from the retired `mailpilot-devops` repo; the guest data disk is plain
**ext4 on a zvol** (no in-guest ZFS).

## Layout

```
kronos   upool/vms/<name>        OS zvol   (Ubuntu cloud image, grown by cloud-init)
         upool/vms/<name>-data   data zvol (guest /dev/vdb)
guest    /dev/vdb  ext4  →  /var/lib/postgresql   (PostgreSQL 18 cluster)
```

The guest gets a static IP (cloud-init netplan) on the libvirt `default` NAT
subnet, a MAC derived from `vm_ip`'s last octet, and a `<name>.vm.internal` DNS
record on the tailnet (network role). Ansible connects as `ubuntu` with the key
from `vm_admin_ssh_key_file` (`group_vars/mailpilot.yml`).

## Commands

- `gmake mailpilot-vm LIMIT=mailpilot-1` — create/boot the guest (mailpilot_vm + host_network roles).
- `gmake mailpilot-config LIMIT=mailpilot-1` — configure the guest: OS tools, operator
  CLIs, ext4 data disk + PostgreSQL 18, optional Tailscale.
- `gmake mailpilot-release [version=X.Y.Z]` — install/upgrade `mailpilot-crm` and
  (re)start the service. Without `version`, the latest PyPI release is used.
- `gmake mailpilot-stats` — SSH (22) reachability + `systemctl is-active` +
  `mailpilot --version` + recent journal.
- `gmake site LIMIT=mailpilot-1` — all three in one pass.
- Single guest roles: `gmake mailpilot-postgresql LIMIT=mailpilot-1`, `gmake mailpilot-tools ...`, etc.

Add an instance by adding a host to the `mailpilot` group in
`ansible/inventory/hosts.yml` with a free IP on the VM subnet, then
`gmake site LIMIT=<name>`.

## Secrets

All deploy-time secrets are **optional** — roles no-op or defer on an empty
value (Postgres stays localhost-only, the guest does not join Tailscale,
operator CLIs are installed but unauthenticated). Supplied via
[`pass(1)`](https://www.passwordstore.org/) under the namespace set by
`pass_namespace` in the Makefile (default `mailpilot-devops`; override with
`gmake mailpilot-config pass_namespace=<ns>`):

| pass key | consumed by |
| --- | --- |
| `TAILSCALE_AUTH_KEY` | tailscale (join the tailnet) |
| `POSTGRESQL_REMOTE_PASSWORD` | mailpilot_postgresql (`pilot` remote role) |
| `POSTGRESQL_READONLY_PASSWORD` | mailpilot_postgresql (`reporter` read-only role) |
| `LOGFIRE_READ_TOKEN` | claude_code (guest `logfire` CLI auth) |
| `ANTHROPIC_API_KEY` | tools (vim-claude, operator use) |
| `FIRECRAWL_API_KEY` | firecrawl_cli |

Git commit signing (`mailpilot_gpg` role) is off unless a key is passed explicitly:

    cd ansible && ansible-playbook site.yml --tags mailpilot_gpg -l mailpilot-1 \
      -e gpg_signing_key=/path/to/signing.key -e gpg_user=ubuntu

## Post-deploy: application configuration

The deploy provisions the database and the systemd unit only. MailPilot reads
its runtime config from `~/.mailpilot/config.json` in the `mailpilot` user's
home (created with defaults on first run). Set app credentials on the guest:

    sudo -u mailpilot mailpilot config set anthropic_api_key sk-ant-...
    sudo -u mailpilot mailpilot config set google_application_credentials /path/to/service-account.json
    sudo -u mailpilot mailpilot account create --email user@example.com --display-name "User Name"
    sudo systemctl restart mailpilot

## Backups

No in-guest snapshot layer: the guest data disk is ext4, and sanoid's nightly
recursive snapshot of `upool/vms` on kronos (sanoid role, see
[backup-strategy.md](backup-strategy.md)) captures the OS and data zvols
crash-consistently. Roll back on kronos, whole-disk, with the VM shut off:

    sudo virsh shutdown mailpilot-1
    sudo zfs rollback upool/vms/mailpilot-1-data@autosnap_...   # and/or the OS zvol
    sudo virsh start mailpilot-1

PostgreSQL crash-recovers from the WAL on boot. For an application-consistent
copy, `pg_dump` before a risky change.
