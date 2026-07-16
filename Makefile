.ONESHELL:
.SILENT:

SHELL := bash
.SHELLFLAGS := -ec

PLAYBOOK = ansible-playbook site.yml
LIMIT_ARG = $(if $(LIMIT),-l $(LIMIT),)

# pass(1) namespace for mailpilot deploy-time secrets (all optional; empty is
# tolerated). Override per-invocation: make config pass_namespace=<ns>
pass_namespace := mailpilot-devops

.PHONY: help site check lint deps ping \
        kvm storage sanoid network fileserver fish vm mssql acumatica \
        config mailpilot status \
        tools postgresql nodejs github_cli google_cli tailscale \
        claude_code firecrawl_cli googleworkspace_cli \
        release major minor patch

comma := ,

# Best-effort secrets from pass(1). Missing keys resolve to empty strings; the
# roles that consume them (tailscale, postgresql remote/reporter, claude_code,
# firecrawl_cli, tools) all no-op or defer on an empty value.
define load_secrets
tailscale_auth_key=$$(pass show $(pass_namespace)/TAILSCALE_AUTH_KEY 2>/dev/null || true)
postgresql_remote_password=$$(pass show $(pass_namespace)/POSTGRESQL_REMOTE_PASSWORD 2>/dev/null || true)
postgresql_readonly_password=$$(pass show $(pass_namespace)/POSTGRESQL_READONLY_PASSWORD 2>/dev/null || true)
logfire_read_token=$$(pass show $(pass_namespace)/LOGFIRE_READ_TOKEN 2>/dev/null || true)
anthropic_api_key=$$(pass show $(pass_namespace)/ANTHROPIC_API_KEY 2>/dev/null || true)
firecrawl_api_key=$$(pass show $(pass_namespace)/FIRECRAWL_API_KEY 2>/dev/null || true)
extra_vars="tailscale_auth_key=$$tailscale_auth_key postgresql_remote_password=$$postgresql_remote_password postgresql_readonly_password=$$postgresql_readonly_password logfire_read_token=$$logfire_read_token anthropic_api_key=$$anthropic_api_key firecrawl_api_key=$$firecrawl_api_key"
endef

# Resolve the mailpilot version: explicit `version=X.Y.Z`, else latest on PyPI.
define resolve_version
v='$(version)'
if [ -z "$$v" ]; then v=$$(curl -fsSL https://pypi.org/pypi/mailpilot-crm/json | jq -r '.info.version'); fi
if [ -z "$$v" ] || [ "$$v" = "null" ]; then echo "could not resolve mailpilot version (pass version=X.Y.Z)"; exit 1; fi
endef

help:
	echo "targets:"
	echo "  ==> Deployment targets <=="
	echo "  site       apply full stack (kronos + acu instances + mailpilot guests)"
	echo "  lint       ansible-lint over the ansible tree"
	echo "  ping       ansible connectivity test (LIMIT=mailpilot for the guests)"
	echo "  ==> kronos host roles <=="
	echo "  kvm        role: hypervisor + VM lifecycle scripts"
	echo "  storage    role: ZFS datasets"
	echo "  sanoid     role: snapshot schedules (VM zvols + mssql backups)"
	echo "  network    role: libvirt NAT / DHCP leases / tailscale router"
	echo "  fileserver role: SMB shares over /upool (distr, mssql-backups)"
	echo "  fish       role: fish shell config for kb"
	echo "  ==> Acumatica instances (group acu) <=="
	echo "  vm         clone/create VMs per inventory — acu and mailpilot (LIMIT=<vm> for one)"
	echo "  mssql      role: per-instance data disk + SQL Server (LIMIT=acu-dev1 for one)"
	echo "  acumatica  role: Acumatica ERP MSI + IIS/ac.exe instance (LIMIT=acu-dev1 for one)"
	echo "  ==> MailPilot guests (group mailpilot) <=="
	echo "  config     configure the guest (OS, data disk, Postgres, operator tooling)"
	echo "  mailpilot  install/upgrade mailpilot-crm + (re)start the service [version=X.Y.Z]"
	echo "  status     systemctl is-active + mailpilot --version + recent journal"
	echo "  <role>     run a single guest role: tools postgresql nodejs github_cli"
	echo "             google_cli tailscale claude_code firecrawl_cli googleworkspace_cli"
	echo "  ==> Release <=="
	echo "  release    tag + publish a GitHub release (make release major|minor|patch)"

site:
	cd ansible
	$(resolve_version)
	$(load_secrets)
	echo "==> Full stack (mailpilot-crm==$$v) <=="
	$(PLAYBOOK) $(LIMIT_ARG) --extra-vars "$$extra_vars mailpilot_version=$$v"

lint: deps
	cd ansible
	ansible-lint

deps:
	cd ansible
	ansible-galaxy collection install -r requirements.yml

kvm storage sanoid network fileserver fish:
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

# guest config only: limit to the mailpilot group so the kronos/acu plays are
# out of scope, then skip the create-VM and app-deploy tags
config:
	cd ansible
	$(load_secrets)
	$(PLAYBOOK) -l $(if $(LIMIT),$(LIMIT),mailpilot) --skip-tags vm$(comma)mailpilot --extra-vars "$$extra_vars"

mailpilot:
	cd ansible
	$(resolve_version)
	echo "==> Deploy mailpilot-crm==$$v <=="
	$(PLAYBOOK) --tags mailpilot $(LIMIT_ARG) --extra-vars "mailpilot_version=$$v"

status:
	cd ansible
	ansible mailpilot $(LIMIT_ARG) -m shell -a "systemctl is-active mailpilot.service; echo '---'; mailpilot --version; echo '---'; journalctl -u mailpilot --no-pager -n 5"

# Single-role convenience targets for the mailpilot guests (secrets threaded).
tools postgresql nodejs github_cli google_cli tailscale claude_code firecrawl_cli googleworkspace_cli:
	cd ansible
	$(load_secrets)
	$(PLAYBOOK) --tags $@ $(LIMIT_ARG) --extra-vars "$$extra_vars"

ping:
	cd ansible
	ansible $(if $(LIMIT),$(LIMIT),kronos) -m ping

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
