.EXPORT_ALL_VARIABLES:
.ONESHELL:
.SILENT:

PLAYBOOK = ansible-playbook site.yml

.PHONY: help site check lint deps ping kvm storage network fileserver fish vm mssql acumatica release major minor patch

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
	echo "  ==> Release <=="
	echo "  release    tag + publish a GitHub release (make release major|minor|patch)"

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

###############################################################################
# Release
###############################################################################

# `make release <part>` passes the part as an extra goal; pick it out and give
# the part words no-op recipes so make does not try to build them. There is no
# version manifest in this repo — the version lives in the git tag, and the next
# one is bumped from the latest `v*` tag.
part := $(word 1,$(filter major minor patch,$(MAKECMDGOALS)))

release:
	set -e
	test -n "$(part)" || { echo "usage: make release major|minor|patch"; exit 1; }
	git diff --quiet && git diff --cached --quiet \
		|| { echo "working tree not clean — commit or stash first"; exit 1; }
	cur=$$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || echo v0.0.0)
	cur=$${cur#v}
	maj=$${cur%%.*}; rest=$${cur#*.}; min=$${rest%%.*}; pat=$${rest##*.}
	case "$(part)" in
	  major) maj=$$((maj + 1)); min=0; pat=0 ;;
	  minor) min=$$((min + 1)); pat=0 ;;
	  patch) pat=$$((pat + 1)) ;;
	esac
	version="$$maj.$$min.$$pat"
	echo "==> Tagging v$$version <=="
	git tag "v$$version"
	git push && git push --tags
	echo "==> Publishing v$$version to GitHub <=="
	gh release create "v$$version" --title "v$$version" --generate-notes
	echo "Released v$$version"

major minor patch:
	:
