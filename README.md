# Acumatica DevOps

Ansible-managed Ubuntu Linux infrastructure for a test/dev **Acumatica ERP** lab.
One Ubuntu Linux host runs KVM. Each Acumatica instance is a Windows Server VM
cloned from a golden image. This README is the operator manual.

Commands below write the host's SSH alias as `<host>` — substitute the name you
gave it in `~/.ssh/config`.

## What this repo does

- Configures the Ubuntu Linux host as a KVM hypervisor with ZFS storage, libvirt
  NAT, SMB shares, and a Tailscale subnet router.
- Clones a Windows Server golden image into one VM per Acumatica instance.
- Installs SQL Server and Acumatica ERP into each instance, unattended.

Everything runs through Ansible from a control machine. All host changes go
through Ansible — do not hand-edit the host directly.

## Prerequisites

Run Ansible from a control machine — a workstation (macOS or Linux) or a CI
runner such as a self-hosted GitHub Actions runner. You need:

- SSH access to the Ubuntu Linux host — see [Remote host](#remote-host).
- Ansible installed locally (for example `brew install ansible` on macOS, or
  `pipx install ansible` / your distro's package on Linux).
- Collection dependencies: `make deps` (runs `ansible-galaxy collection install`).

Confirm connectivity before applying anything:

    make ping        # ansible <host> -m ping

## Remote host

Connect with `ssh <host>`, where `<host>` is an alias in your `~/.ssh/config`.
The lab resolves it to a Tailscale MagicDNS name. Host runs Ubuntu 26.04 LTS.

- **Do all work as `kb`** (uid/gid 1001). `ssh <host>` logs in as `kb`.
- Use `sudo -n` for privileged steps. Both `kb` and `sysop` have passwordless
  sudo (`/etc/sudoers.d/90-nopasswd`).
- `sysop` (uid 1000) is the break-glass admin account only. Root SSH is disabled.
- kb's login shell is **fish** (via the `fish_shell` role). `ssh <host> '<cmd>'`
  is interpreted by fish. POSIX-isms fail — `x=y` assignments, `$(...)` in double
  quotes, or a stray `$` (for example in a sed/awk script). For POSIX syntax run
  `ssh <host> bash -c '...'`.

## Storage layout (ZFS)

Pool is `upool`. Acumatica-related datasets:

- `upool/vms` — VM disks, one zvol per VM (`upool/vms/<name>`, plus `-data` and
  `-backup` zvols). Snapshotted daily by one atomic `zfs snapshot -r`
  (`vm_snap_keep` kept) as a crash-consistent whole-VM rollback net.
- `upool/distr` → `/upool/distr` — ISO images and installers (Acumatica MSI, SQL
  Server ISO). SMB share `\\<host>\distr`.
- `upool/backups/mssql` → `/upool/backups/mssql` — SQL Server backups. SMB share
  `\\<host>\mssql-backups`.

## Everyday commands

All targets wrap `ansible-playbook site.yml`. Run from the repo root.

- `make site` — apply the full stack: the Ubuntu Linux host, then clone and
  provision every `acu` instance.
- `make ping` — Ansible connectivity test against the Ubuntu Linux host.
- `make lint` — `ansible-lint` over the ansible tree.
- `make deps` — install collection dependencies.
- `make help` — list all targets.

`LIMIT=<vm>` scopes a target to one instance. For example:

    make vm LIMIT=acu-dev1          # clone + DHCP/DNS + rename one VM
    make mssql LIMIT=acu-dev1       # data disk + SQL Server for one VM
    make acumatica LIMIT=acu-dev1   # Acumatica MSI + IIS/ac.exe for one VM

Single-role targets for the host stack: `make kvm`, `make storage`,
`make network`, `make fileserver`, `make fish`.

## Add an Acumatica instance

Instances are inventory-driven. Adding a host is all it takes.

1. Add the VM under the `acu` group in `ansible/inventory/hosts.yml` with its
   reserved IP:

       acu:
         hosts:
           acu-tst1: { vm_ip: 192.168.122.12 }

2. Apply the stack:

       make site                # clone -> rename -> mssql -> acumatica
       make vm LIMIT=acu-tst1   # or just the clone + lease/DNS + rename step

The MAC is derived from `vm_ip`'s last octet, so the static DHCP lease and the
`<name>.vm.internal` DNS record exist before the VM first boots. The site lands
at `http://<vm>.vm.internal/` — first login `admin`/`setup` (password change
forced).

Golden-image build, instance internals, and Tailscale access are documented in
[docs/windows-vms.md](docs/windows-vms.md). The backup strategy — SQL-native
`.bak` backups plus ZFS zvol snapshots — is in
[docs/backup-strategy.md](docs/backup-strategy.md).

## Role reference

`site.yml` runs three plays: the Ubuntu Linux host stack, guest VM cloning, then
the Windows guests. Roles in order:

- **kvm** — hypervisor plus `win-vm-create`, `win-vm-rm`, and `qga-exec` helper
  scripts. Golden-image build, teardown, guest-agent rescue.
- **storage** — ZFS datasets plus the snapshot schedules (daily recursive
  snapshot of the VM zvols and daily snapshot of the MSSQL backup dataset).
- **network** — libvirt NAT, static DHCP leases, Tailscale subnet router,
  split-DNS dnsmasq. VMs resolve as `<vm>.vm.internal` on the tailnet.
- **fileserver** — SMB shares over `/upool`: `distr`, `mssql-backups`.
- **vm_clone** — inventory-driven guest provisioning. An `acu` host with `vm_ip`
  gets a derived MAC, a ZFS clone of `ws2025-base`, and a first-boot rename.
  `make vm LIMIT=<vm>`.
- **mssql** — per-instance Windows layer: a data-disk zvol plus unattended SQL
  Server. Runs against inventory group `acu` over SSH to Administrator
  (`ansible_shell_type: powershell`); host-side steps delegate to the host.
  `make mssql LIMIT=<vm>`.
- **acumatica** — Acumatica ERP: installer MSI from the distr share into the
  guest, then IIS plus `ac.exe` instance deployment. Produces AcumaticaDB and a
  site at `http://<vm>/AcumaticaERP`. `make acumatica LIMIT=<vm>`.
- **fish_shell** — fish config for kb.
