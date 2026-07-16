# Windows Server / Acumatica instances

VM disks are ZFS zvols (`upool/vms/<name>`, sparse, 64k volblocksize). A
**golden image** is cloned per Acumatica instance with `zfs clone` — instant,
no data copied. All commands below run on the Ubuntu Linux host with sudo. That
host is written as `<host>` in `ssh` and SMB paths — substitute the name you
gave it in `~/.ssh/config`.

## 1. Build the golden image (once per Windows Server version)

1. Put a Windows Server ISO in `/upool/distr/iso/` (e.g. the
   [Evaluation Center](https://www.microsoft.com/en-us/evalcenter/) ISO —
   not redistributable, so it is downloaded manually, not by ansible).
2. Create the VM (UEFI, TPM 2.0, virtio disk/NIC, VNC on localhost):

       sudo win-vm-create ws2025-base /upool/distr/iso/<ws-iso> 120G 8192 4

3. Connect to the console from your workstation and run Windows Setup:

       ssh -L 5900:127.0.0.1:5900 <host>     # then VNC to localhost:5900

   The disk is invisible until you *Load driver* → virtio-win CD →
   `vioscsi`/`viostor` and `NetKVM` for the NIC.
4. In Windows: install all virtio-win guest tools (from the second CD),
   Windows updates, OpenSSH server (+ your key in
   `C:\ProgramData\ssh\administrators_authorized_keys`), RDP, and anything
   every instance should share. Do **not** install MSSQL in the golden image
   (it bakes the machine name in at install time — install it per instance,
   after the rename).
5. Shut down (`shutdown /s /t 0`) and snapshot the baseline:

       sudo zfs snapshot upool/vms/ws2025-base@base-$(date +%Y%m%d)

6. The golden VM stays **shut off** — it exists only to be cloned.

The image is deliberately **not sysprepped**: this is a workgroup-only lab
(no AD, WSUS, or KMS), where duplicate machine SIDs are harmless — see
Russinovich's "machine SID duplication myth". Clones boot straight to the
login screen with networking up; the trade-offs are that clones share the
golden image's remaining eval days and its SSH host keys (regenerate with
`Remove-Item C:\ProgramData\ssh\ssh_host_*; Restart-Service sshd` if you
care).

## 2. Provision an Acumatica instance

Instances are **inventory-driven**: add the VM under the `acu` group in
`ansible/inventory/hosts.yml` with its reserved IP, then apply the stack —

    acu:
      hosts:
        acu-tst1: { vm_ip: 192.168.122.12 }

    make site                          # everything: clone -> rename -> mssql -> acumatica
    make acumatica-vm LIMIT=acu-tst1   # or just the clone + lease/DNS + rename step

The `acumatica_vm` play (delegating host steps to the Ubuntu Linux host) per instance:

- derives a stable MAC from `vm_ip`'s last octet (`52:54:00:7a:00:xx`;
  override with `vm_mac` — acu-dev1 keeps its pre-derivation MAC this way),
  so the static DHCP lease and the `<name>.vm.internal` DNS record from the
  `host_network` role are registered **before the VM first boots**;
- if the domain doesn't exist, snapshots and `zfs clone`s the golden zvol into
  `upool/vms/<name>` (instant, no copy), then `virt-clone --preserve-data`
  registers a libvirt domain on it (fresh UUID, the derived MAC) — all native
  Ansible tasks in the role, no wrapper script;
- starts the VM, waits for the baked-in SSH, renames the guest to its
  inventory name and reboots.

Each clone gets its own zvol (`upool/vms/acu-tst1`, a clone of
`upool/vms/ws2025-base@acu-tst1`). No sysprep, so the clone boots straight
to the login screen, SSH/RDP reachable with the golden image's credentials.
The rename happens **before the acumatica_mssql role installs SQL Server** (the
machine name is recorded at install time; renaming afterwards needs
`sp_dropserver`/`sp_addserver`) — the role asserts this.
Installers (Acumatica MSI, SQL Server ISO, …) are on the `\\<host>\distr`
share (dataset `upool/distr`, `host_smb` role): `installers/` for
application setups, `iso/` for OS/driver images. Credentials: user
`svc-distr`, password in `/root/svc-distr.smbpasswd` on the host.
Remove an instance with `sudo win-vm-rm acu-dev1 --yes` (the golden zvol
cannot be removed while clones depend on it).

### Data disk + SQL Server (ansible)

The `acumatica_mssql` role provisions the data disk and SQL Server (guests are
ansible-managed over SSH — inventory group `acu`, connection vars in
`group_vars/acu.yml`). It runs as part of `make site`; for one instance:

    make acumatica-config LIMIT=acu-dev1

The play is idempotent; per guest it

- creates a **separate data zvol** `upool/vms/<name>-data` (sparse, 64k
  volblocksize, default 100G — `mssql_data_disk_size`), hot-plugs it as a
  second virtio disk, and formats it as `D:` (NTFS, 64K allocation unit).
  Separate from the OS zvol so `zfs rollback` of the OS disk never touches
  the databases;
- downloads the SQL Server 2025 **Developer (Enterprise)** ISO to the distr
  share once, presents it to the guest via the clone's CD drive
  (`virsh change-media` — no share credentials needed in the guest), and runs
  an unattended install: engine + agent, mixed mode, TCP 1433 open,
  data/log/tempdb on `D:\MSSQL`;
- generates the `sa` password on the host at `/root/mssql-sa-<name>.pass`
  (`BUILTIN\Administrators` is also sysadmin, so Windows auth works too);
- installs SQL Server Management Studio 22 (bootstrapper from
  `aka.ms/ssms/22`; the payload downloads from Microsoft at install time,
  which is also why it isn't staged on the distr share).

Setup failures are logged in the guest under
`C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt`.
Note `win-vm-rm` removes only the OS zvol — destroy `upool/vms/<name>-data`
manually once you are sure the data is disposable.

### Acumatica (ansible)

The `acumatica_erp` role installs the Acumatica ERP MSI and deploys the
application instance in one pass:

    make acumatica-release LIMIT=acu-dev1

First the installer (`installers/AcumaticaERPInstall-<version>.msi` on the
distr share — stage new builds there manually and bump `acumatica_version`):
the MSI is copied into the guest over `\\<host>\distr` (svc-distr credential
read from the host) and run unattended, laying down the Configuration Wizard
and `ac.exe` under `C:\Program Files\Acumatica ERP`.

Then the instance: it enables IIS + ASP.NET 4.8 and runs
`ac.exe -configmode:"NewInstance"`:
database `AcumaticaDB` on the local SQL Server (created new; runtime
connection uses the sa password from the host), site
`C:\Acumatica\AcumaticaERP` under Default Web Site, one visible tenant
(`acumatica_tenant_type: SalesDemo` preloads demo data; default is a clean
template). Port 80 is opened and the site root 302s to the instance
(httpRedirect in the Default Web Site's web.config, disabled inside the app
via a `<location>` override so it can't loop), so `http://<vm>.vm.internal/`
from the tailnet lands on the login page — first login `admin`/`setup`
(password change forced). Re-deploying from scratch means dropping both the
IIS app and the database, then re-running the role.

### Access over Tailscale

The Ubuntu Linux host is a Tailscale **subnet router** for the VM network
(192.168.122.0/24, `host_network` role) — any tailnet device reaches VMs directly:
RDP to `192.168.122.x`, browse Acumatica on `http://192.168.122.x`, etc. The
advertised route needs a **one-time approval** in the Tailscale admin console
(Machines → the host → route settings).

Stable IPs come from the inventory (`vm_ip` per host — the `host_network` role
turns them into static DHCP leases and DNS records). Fallback without the
approved route: `ssh -L 3389:<vm-ip>:3389 <host>`.

### In-guest rescue without SSH/RDP

`qga-exec` (on the host) runs a command inside a Windows VM through the QEMU
guest agent — works even when SSH and RDP are broken:

    sudo qga-exec ws2025-base 'C:\Windows\System32\whoami.exe'
    sudo qga-exec acu-dev1 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' \
        -NoProfile -Command 'Restart-Service sshd'

## 3. MSSQL backup / recovery

Two complementary layers — nightly SQL-native `.bak` backups (per-database,
restorable anywhere) and daily crash-consistent ZFS zvol snapshots (whole-VM
rollback) — both Ansible-provisioned. The full design, schedule, retention,
restore commands, and configuration knobs live in
[backup-strategy.md](backup-strategy.md).
