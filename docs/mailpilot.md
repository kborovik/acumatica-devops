# MailPilot guests

One Ubuntu 26.04 guest per [MailPilot](https://github.com/kborovik/mailpilot)
instance on kronos, created from the Ubuntu cloud image (zvols + cloud-init) and
running `mailpilot-crm` from PyPI as the `mailpilot.service` systemd unit
under the interactive `ubuntu` login (no dedicated service account).
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
record on the tailnet (network role). Guests do **not** run Tailscale; kronos
is the subnet router. Ansible connects as `ubuntu` at `vm_ip` via
**`ProxyJump=kronos`** (`group_vars/mailpilot.yml`) with the key from
`vm_admin_ssh_key_file`.

Interactive SSH (via kronos or the advertised subnet route):

    ssh -J kronos ubuntu@192.168.122.20
    ssh ubuntu@mailpilot-1.vm.internal

## Commands

- `gmake mailpilot-vm LIMIT=mailpilot-1` — create/boot the guest (mailpilot_vm + host_network roles).
- `gmake mailpilot-config LIMIT=mailpilot-1` — configure the guest: OS tools, operator
  CLIs, ext4 data disk + PostgreSQL 18.
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

Two stores, same split as Acumatica Windows passwords:

| Kind | Where | Examples |
| --- | --- | --- |
| **External** (operator-supplied) | [`pass(1)`](https://www.passwordstore.org/) on the control machine | API tokens, GCP SA JSON |
| **Generated lab passwords** | root-only files on **kronos** | Postgres `pilot` / `reporter` (like MSSQL `sa` / SMB) |

### External secrets (`pass`)

Optional — roles no-op or defer on an empty value (operator CLIs install but
stay unauthenticated). Loaded by the Makefile under `pass_namespace` (default
**`acumatica-devops`**; override with `gmake mailpilot-config pass_namespace=<ns>`):

| pass key | consumed by |
| --- | --- |
| `LOGFIRE_READ_TOKEN` | mailpilot_claude_code (`logfire` CLI) |
| `ANTHROPIC_API_KEY` | mailpilot_tools (vim-claude, operator use) |
| `FIRECRAWL_API_KEY` | mailpilot_firecrawl_cli |
| `GOOGLE_APPLICATION_CREDENTIALS` | mailpilot_crm (SA JSON for ADC off-GCP) |

Encrypt the namespace with the Lab5 GPG key (same fingerprint as
`gcp-devops/.gpg-id`), then insert keys:

    pass init -p acumatica-devops E4AFCA7FBB19FC029D519A524AEBB5178D5E96C1
    # … keys from the table
    # service-account JSON (full file contents, multi-line):
    pass insert -m acumatica-devops/GOOGLE_APPLICATION_CREDENTIALS < ./sa.json

`GOOGLE_APPLICATION_CREDENTIALS` is the GCP service-account JSON used when the
guest is **not** on Google Cloud (no Workload Identity). On deploy,
`mailpilot_crm` writes it to
`/home/ubuntu/.config/gcloud/application_default_credentials.json`, runs
`mailpilot config set google_application_credentials <path>`, and sets
`Environment=GOOGLE_APPLICATION_CREDENTIALS=…` on `mailpilot.service`.

Audit (existence only; never prints values):

    gmake secrets-check           # OK / MISS for external keys + .gpg-id check
    gmake secrets-check STRICT=1  # exit 1 if any key is missing

### Generated passwords (kronos)

The `mailpilot_postgresql` role generates (once) and reads:

| file on kronos | PostgreSQL role |
| --- | --- |
| `/root/mailpilot-pg-remote-<host>.pass` | `pilot` (remote) |
| `/root/mailpilot-pg-readonly-<host>.pass` | `reporter` (read-only) |

Same process as `/root/mssql-sa-<host>.pass`: `umask 077`, create-if-missing,
Ansible slurps from kronos. Optional override: pass
`-e postgresql_remote_password=…` / `-e postgresql_readonly_password=…` (escape
hatch); empty default always uses the host files.

Read a password: `ssh kronos -- sudo cat /root/mailpilot-pg-remote-mailpilot-1.pass`.

Git commit signing (`mailpilot_gpg` role) is off unless a key is passed explicitly:

    cd ansible && ansible-playbook site.yml --tags mailpilot_gpg -l mailpilot-1 \
      -e gpg_signing_key=/path/to/signing.key -e gpg_user=ubuntu

## Post-deploy: application configuration

The deploy provisions the database, the systemd unit, and (when present in
`pass`) the Google service-account JSON + `google_application_credentials`
config. Daemon and CLI run as **`ubuntu`** (same account you SSH as). Runtime
config is `~/.mailpilot/config.json` under that home. Set app credentials as
`ubuntu`:

    mailpilot config set anthropic_api_key sk-ant-...
    # google_application_credentials is set by mailpilot_crm when
    # acumatica-devops/GOOGLE_APPLICATION_CREDENTIALS is in pass
    mailpilot account create --email user@example.com --display-name "User Name"
    sudo systemctl restart mailpilot

Verify on the guest:

    mailpilot config get
    # google_application_credentials → /home/ubuntu/.config/gcloud/application_default_credentials.json
    systemctl show mailpilot -p Environment
    systemctl status mailpilot

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
