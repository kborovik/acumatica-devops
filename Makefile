.ONESHELL:
.SILENT:

SHELL := bash
.SHELLFLAGS := -ec

export TERM := xterm-256color

PLAYBOOK = ansible-playbook site.yml
LIMIT_ARG = $(if $(LIMIT),-l $(LIMIT),)

comma := ,

# pass(1) namespace for mailpilot deploy-time secrets (all optional; empty is
# tolerated). Override per-invocation: make mailpilot-config pass_namespace=<ns>
pass_namespace := mailpilot-devops

.PHONY: default help site lint deps ping \
        host-base host-kvm host-storage host-network host-smb \
        acumatica-vm acumatica-config acumatica-release acumatica-status \
        mailpilot-vm mailpilot-config mailpilot-release mailpilot-stats \
        mailpilot-tools mailpilot-postgresql mailpilot-nodejs mailpilot-github-cli \
        mailpilot-google-cli mailpilot-tailscale mailpilot-claude-code \
        mailpilot-firecrawl-cli mailpilot-googleworkspace-cli \
        release major minor patch

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

# $(call tags,<tag>[,<tag>...]) — run the kronos host plays for one or more role
# tags. Pass several with $(comma): $(call tags,storage$(comma)sanoid)
define tags
cd ansible
$(PLAYBOOK) --tags $(1)
endef

###############################################################################
# Colors and headers
###############################################################################

blue := $$(tput setaf 4)
green := $$(tput setaf 2)
yellow := $$(tput setaf 3)
reset := $$(tput sgr0)

define header
echo "$(blue)==> $(1) <==$(reset)"
endef

default: help

help:
	echo "$(blue)Usage: $(green)make [recipe] [LIMIT=<host>]$(reset)"
	echo "$(blue)Recipes:$(reset)"
	awk 'BEGIN {FS = ":.*?## "; sort_cmd = "sort"} /^[a-zA-Z0-9_-]+:.*?## / \
	{ printf "  \033[33m%-20s\033[0m %s\n", $$1, $$2 | sort_cmd; } \
	END {close(sort_cmd)}' $(MAKEFILE_LIST)

###############################################################################
# Deployment
###############################################################################

site: ## apply the full stack (kronos host + acu instances + mailpilot guests)
	cd ansible
	$(resolve_version)
	$(load_secrets)
	$(call header,Full stack: mailpilot-crm==$$v)
	$(PLAYBOOK) $(LIMIT_ARG) --extra-vars "$$extra_vars mailpilot_version=$$v"

lint: deps ## ansible-lint over the ansible tree
	cd ansible
	ansible-lint

ping: ## ansible connectivity test (LIMIT=mailpilot for the guests)
	cd ansible
	ansible $(if $(LIMIT),$(LIMIT),kronos) -m ping

deps:
	cd ansible
	ansible-galaxy collection install -r requirements.yml

###############################################################################
# kronos host roles
###############################################################################

host-base: ## kronos base config — fish shell for kb (+ future host tweaks)
	$(call tags,host_base)

host-kvm: ## hypervisor + VM lifecycle scripts (win-vm-*, qga-exec)
	$(call tags,host_kvm)

host-storage: ## ZFS datasets + sanoid snapshot schedules (VM zvols + mssql backups)
	$(call tags,host_storage$(comma)host_sanoid)

host-network: ## libvirt NAT / DHCP leases / split-DNS + tailscale subnet router
	$(call tags,host_network)

host-smb: ## SMB shares over /upool (distr, mssql-backups)
	$(call tags,host_smb)

###############################################################################
# Acumatica instances (group acu)
###############################################################################

# network tag runs too so the clone's DHCP lease / DNS record exist before first
# boot; kronos stays in the limit or the network play is skipped.
acumatica-vm: ## clone/create the Acumatica Windows VMs (LIMIT=acu-dev1 for one)
	cd ansible
	$(PLAYBOOK) --tags host_network$(comma)acumatica_vm -l kronos$(comma)$(if $(LIMIT),$(LIMIT),acu)

# everything on the acu VMs except the VM clone and the Acumatica app itself:
# data disk + SQL Server today, plus any future supporting roles.
acumatica-config: ## SQL Server + supporting software on the acu VMs (LIMIT=acu-dev1 for one)
	cd ansible
	$(PLAYBOOK) -l $(if $(LIMIT),$(LIMIT),acu) --skip-tags acumatica_vm$(comma)acumatica_erp

acumatica-release: ## install the Acumatica ERP MSI + IIS/ac.exe instance (LIMIT=acu-dev1 for one)
	cd ansible
	$(PLAYBOOK) --tags acumatica_erp $(LIMIT_ARG)

acumatica-status: ## acu VM reachability — SSH (22) + IIS (80) port checks
	cd ansible
	for h in $$(ansible acu $(LIMIT_ARG) --list-hosts 2>/dev/null | tail -n +2); do
	  ip=$$(ansible-inventory --host $$h 2>/dev/null | jq -r '.vm_ip')
	  for p in 22 80; do
	    nc -z -w2 $$ip $$p 2>/dev/null && echo "$$h ($$ip:$$p) open" || echo "$$h ($$ip:$$p) closed"
	  done
	done

###############################################################################
# MailPilot guests (group mailpilot)
###############################################################################

# network tag runs too so the guest's DHCP lease / DNS record exist before first
# boot; kronos stays in the limit or the network play is skipped.
mailpilot-vm: ## create the MailPilot Ubuntu guests (LIMIT=mailpilot-1 for one)
	cd ansible
	$(PLAYBOOK) --tags host_network$(comma)mailpilot_vm -l kronos$(comma)$(if $(LIMIT),$(LIMIT),mailpilot)

# guest config only: limit to the mailpilot group so the kronos/acu plays are out
# of scope, then skip the create-VM and app-deploy tags.
mailpilot-config: ## configure the MailPilot guests — OS, data disk, Postgres, operator tooling
	cd ansible
	$(load_secrets)
	$(PLAYBOOK) -l $(if $(LIMIT),$(LIMIT),mailpilot) --skip-tags mailpilot_vm$(comma)mailpilot_crm --extra-vars "$$extra_vars"

mailpilot-release: ## install/upgrade mailpilot-crm + (re)start the service [version=X.Y.Z]
	cd ansible
	$(resolve_version)
	$(call header,Deploy mailpilot-crm==$$v)
	$(PLAYBOOK) --tags mailpilot_crm $(LIMIT_ARG) --extra-vars "mailpilot_version=$$v"

mailpilot-stats: ## MailPilot service status + SSH (22) reachability
	cd ansible
	for h in $$(ansible mailpilot $(LIMIT_ARG) --list-hosts 2>/dev/null | tail -n +2); do
	  ip=$$(ansible-inventory --host $$h 2>/dev/null | jq -r '.vm_ip')
	  nc -z -w2 $$ip 22 2>/dev/null && echo "$$h ($$ip:22) open" || echo "$$h ($$ip:22) closed"
	done
	ansible mailpilot $(LIMIT_ARG) -m shell -a "systemctl is-active mailpilot.service; echo '---'; mailpilot --version; echo '---'; journalctl -u mailpilot --no-pager -n 5"

# Single-role convenience targets for the mailpilot guests (secrets threaded).
# The tag is the target name with hyphens flipped to underscores, matching the
# role/tag names in site.yml:
#   make mailpilot-tools | mailpilot-postgresql | mailpilot-nodejs |
#        mailpilot-github-cli | mailpilot-google-cli | mailpilot-tailscale |
#        mailpilot-claude-code | mailpilot-firecrawl-cli |
#        mailpilot-googleworkspace-cli   [LIMIT=mailpilot-1]
mailpilot-tools mailpilot-postgresql mailpilot-nodejs mailpilot-github-cli mailpilot-google-cli mailpilot-tailscale mailpilot-claude-code mailpilot-firecrawl-cli mailpilot-googleworkspace-cli:
	cd ansible
	$(load_secrets)
	$(PLAYBOOK) --tags $(subst -,_,$@) $(LIMIT_ARG) --extra-vars "$$extra_vars"

###############################################################################
# Release
###############################################################################

# `make release <part>` passes the part as an extra goal; pick it out and give
# the part words no-op recipes so make does not try to build them. There is no
# version manifest in this repo — the version lives in the git tag, and the next
# one is bumped from the latest `v*` tag.
part := $(word 1,$(filter major minor patch,$(MAKECMDGOALS)))

release: ## tag + publish a GitHub release (make release major|minor|patch)
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
	$(call header,Tagging v$$version)
	git tag "v$$version"
	git push && git push --tags
	$(call header,Publishing v$$version to GitHub)
	gh release create "v$$version" --title "v$$version" --generate-notes
	echo "$(green)Released v$$version$(reset)"

major minor patch:
	:
