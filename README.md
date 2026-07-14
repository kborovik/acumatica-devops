# Acumatica DevOps

Ansible-managed Ubuntu Linux infrastructure for a test/dev **Acumatica ERP** lab.
One host, `kronos`, runs KVM. Each Acumatica instance is a Windows Server VM
cloned from a golden image. This README is the operator manual.

## What this repo does

- Configures `kronos` as a KVM hypervisor with ZFS storage, libvirt NAT, SMB
  shares, and a Tailscale subnet router.
- Clones a Windows Server golden image into one VM per Acumatica instance.
- Installs SQL Server and Acumatica ERP into each instance, unattended.

Everything runs through Ansible from your Mac. All host changes go through
Ansible — do not hand-edit `kronos`.

## Prerequisites

Run Ansible from your Mac (the control machine). You need:

- SSH access to `kronos` — see [Remote host](#remote-host).
- Ansible installed locally (`brew install ansible`).
- Collection dependencies: `make deps` (runs `ansible-galaxy collection install`).

Confirm connectivity before applying anything:

    make ping        # ansible kronos -m ping

## Remote host

Connect with `ssh kronos`. The name resolves to its Tailscale MagicDNS name via
`~/.ssh/config`. Host runs Ubuntu 26.04 LTS.

- **Do all work as `kb`** (uid/gid 1001). `ssh kronos` logs in as `kb`.
- Use `sudo -n` for privileged steps. Both `kb` and `sysop` have passwordless
  sudo (`/etc/sudoers.d/90-nopasswd`).
- `sysop` (uid 1000) is the break-glass admin account only. Root SSH is disabled.
- kb's login shell is **fish** (via the `fish_shell` role). `ssh kronos '<cmd>'`
  is interpreted by fish. POSIX-isms fail — `x=y` assignments, `$(...)` in double
  quotes, or a stray `$` (for example in a sed/awk script). For POSIX syntax run
  `ssh kronos bash -c '...'`.

## Storage layout (ZFS)

Pool is `upool`. Key datasets:

- `upool/kb` → `/home/kb` — kb's home.
- `upool/documents` → `/home/kb/Documents` — separate dataset nested in the home.
- `upool/kb-old-20260704` — old pre-2026-07 home, archived read-only. Kept
  unmounted. Browse with `sudo zfs mount upool/kb-old-20260704`.
- `upool/vms` — VM disks, one zvol per VM (`upool/vms/<name>`).
- `upool/distr` → `/upool/distr` — ISO images and installers. SMB share
  `\\kronos\distr`.
- `upool/docker` — Docker storage.

Snapshots named `ret1y-vol-*` come from an existing retention tool — do not touch.

## Everyday commands

All targets wrap `ansible-playbook site.yml`. Run from the repo root.

- `make site` — apply the full stack: kronos host, then clone and provision every
  `acu` instance.
- `make ping` — Ansible connectivity test against kronos.
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

Golden-image build, instance internals, MSSQL backup/recovery, and Tailscale
access are documented in [docs/windows-vms.md](docs/windows-vms.md).

## Role reference

`site.yml` runs three plays: the kronos host stack, guest VM cloning, then the
Windows guests. Roles in order:

- **kvm** — hypervisor plus `win-vm-create`, `win-vm-rm`, and `qga-exec` helper
  scripts. Golden-image build, teardown, guest-agent rescue.
- **storage** — ZFS datasets and the backup snapshot schedule.
- **network** — libvirt NAT, static DHCP leases, Tailscale subnet router,
  split-DNS dnsmasq. VMs resolve as `<vm>.vm.internal` on the tailnet.
- **fileserver** — SMB shares over `/upool`: `distr`, `mssql-backups`.
- **vm_clone** — inventory-driven guest provisioning. An `acu` host with `vm_ip`
  gets a derived MAC, a ZFS clone of `ws2025-base`, and a first-boot rename.
  `make vm LIMIT=<vm>`.
- **mssql** — per-instance Windows layer: a data-disk zvol plus unattended SQL
  Server. Runs against inventory group `acu` over SSH to Administrator
  (`ansible_shell_type: powershell`); host-side steps delegate to kronos.
  `make mssql LIMIT=<vm>`.
- **acumatica** — Acumatica ERP: installer MSI from the distr share into the
  guest, then IIS plus `ac.exe` instance deployment. Produces AcumaticaDB and a
  site at `http://<vm>/AcumaticaERP`. `make acumatica LIMIT=<vm>`.
- **fish_shell** — fish config for kb.
