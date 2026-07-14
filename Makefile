.EXPORT_ALL_VARIABLES:
.ONESHELL:
.SILENT:

PLAYBOOK = ansible-playbook site.yml

.PHONY: help site check lint deps ping kvm storage network fileserver fish vm mssql acumatica

comma := ,

help:
	echo "targets:"
	echo "  ==> Deployment targets <=="
	echo "  site       apply full stack (kronos + acu instances)"
	echo "  lint       ansible-lint over the ansible tree"
	echo "  ping       ansible connectivity test"
	echo "  ==> Ansible roles <=="
	echo "  kvm        role: hypervisor + VM lifecycle scripts"
	echo "  storage    role: ZFS datasets + backup snapshot schedule"
	echo "  network    role: libvirt NAT / DHCP leases / tailscale router"
	echo "  fileserver role: SMB shares over /upool (distr, mssql-backups)"
	echo "  vm         role: clone VMs from the golden image per inventory (LIMIT=acu-tst1 for one)"
	echo "  mssql      role: per-instance data disk + SQL Server (LIMIT=acu-dev1 for one)"
	echo "  acumatica  role: Acumatica ERP MSI + IIS/ac.exe instance (LIMIT=acu-dev1 for one)"
	echo "  fish       role: fish shell config for kb"

site:
	cd ansible
	$(PLAYBOOK)

lint: deps
	cd ansible
	ansible-lint

deps:
	cd ansible
	ansible-galaxy collection install -r requirements.yml

kvm storage network fileserver fish:
	cd ansible
	$(PLAYBOOK) --tags $@

# network tag runs too so the clone's DHCP lease / DNS record exist before
# first boot; kronos must stay in the limit or that play would be skipped
vm:
	cd ansible
	$(PLAYBOOK) --tags network$(comma)vm $(if $(LIMIT),-l kronos$(comma)$(LIMIT),)

mssql acumatica:
	cd ansible
	$(PLAYBOOK) --tags $@ $(if $(LIMIT),-l $(LIMIT),)

ping:
	cd ansible
	ansible kronos -m ping
