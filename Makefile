# .ONESHELL needs GNU Make ≥ 3.82. macOS ships 3.81 (/usr/bin/make); without
# oneshell each recipe line is a separate shell and multi-line macros such as
# resolve_version / load_secrets lose their state (empty mailpilot version).
# On macOS use Homebrew's gmake: brew install make && gmake <target>
ifeq ($(filter oneshell,$(.FEATURES)),)
$(error GNU Make ≥ 3.82 required (this is $(MAKE_VERSION) from $(MAKE)). On macOS: brew install make && gmake <target>)
endif

.ONESHELL:
.SILENT:

SHELL := bash
.SHELLFLAGS := -ec

export TERM := xterm-256color

PLAYBOOK = ansible-playbook site.yml
LIMIT_ARG = $(if $(LIMIT),-l $(LIMIT),)

comma := ,

# pass(1) namespace for external mailpilot deploy-time secrets (API keys).
# All optional; empty is tolerated. Postgres pilot/reporter passwords are
# host-local on kronos (not in pass). Override per-invocation:
# gmake mailpilot-config pass_namespace=<ns>
pass_namespace := acumatica-devops
# Lab5 deploy key — same fingerprint as gcp-devops/.gpg-id
pass_gpg_id := E4AFCA7FBB19FC029D519A524AEBB5178D5E96C1
PASSWORD_STORE_DIR ?= $(HOME)/.password-store

.PHONY: default help site lint deps ping secrets-check \
        host-base host-kvm host-storage host-network host-smb \
        linux-unattended-upgrades linux-uv \
        acumatica-vm acumatica-config acumatica-release acumatica-status \
        mailpilot-vm mailpilot-config mailpilot-release mailpilot-status \
        mailpilot-unit-check \
        mailpilot-tools mailpilot-postgresql mailpilot-nodejs mailpilot-github-cli \
        mailpilot-google-cli mailpilot-claude-code \
        mailpilot-firecrawl-cli \
        release major minor patch

# Best-effort secrets from pass(1). Missing keys resolve to empty strings; the
# roles that consume them (claude_code, firecrawl_cli, tools, mailpilot_crm)
# all no-op or defer on an empty value. Postgres passwords are loaded from
# kronos. Multi-line SA JSON is base64 so it survives extra-vars.
# xai_api_key lives outside pass_namespace (shared Grok key under grok/).
define load_secrets
logfire_read_token=$$(pass show $(pass_namespace)/LOGFIRE_READ_TOKEN 2>/dev/null || true)
anthropic_api_key=$$(pass show $(pass_namespace)/ANTHROPIC_API_KEY 2>/dev/null || true)
firecrawl_api_key=$$(pass show $(pass_namespace)/FIRECRAWL_API_KEY 2>/dev/null || true)
google_application_credentials_b64=$$(pass show $(pass_namespace)/GOOGLE_APPLICATION_CREDENTIALS 2>/dev/null | base64 | tr -d '\n' || true)
xai_api_key=$$(pass show grok/GROK_API_KEY 2>/dev/null || true)
extra_vars="logfire_read_token=$$logfire_read_token anthropic_api_key=$$anthropic_api_key firecrawl_api_key=$$firecrawl_api_key google_application_credentials_b64=$$google_application_credentials_b64 xai_api_key=$$xai_api_key"
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

# $(call status_check,<group>,<ports>) — TCP reachability of a group's hosts.
# One ansible-inventory query yields host+IP (honors LIMIT via -l); each port
# gets a 1s nc connect probe. Pure reachability — no SSH login, never blocks on
# a down host. Darwin nc caps the connect with -G (its -w is idle-only); other
# platforms use -w.
define status_check
cd ansible
nct=$$([ "$$(uname -s)" = Darwin ] && echo -G1 || echo -w1)
ansible-inventory --list $(LIMIT_ARG) 2>/dev/null | jq -r '._meta.hostvars as $$hv | (.$(1).hosts // [])[] | "\(.) \($$hv[.].vm_ip)"' | while read -r h ip; do
for p in $(2); do
nc -z $$nct $$ip $$p 2>/dev/null && echo "$$h ($$ip:$$p) open" || echo "$$h ($$ip:$$p) closed"
done
done
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
	echo "$(blue)Usage: $(green)gmake [recipe] [LIMIT=<host>]$(reset)"
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

# Existence-only audit of external pass keys (never prints secret values).
# STRICT=1 exits non-zero if any key is missing.
secrets-check: ## OK/MISS for pass external secrets under pass_namespace
	$(call header,pass namespace: $(pass_namespace))
	gpg_id_file="$(PASSWORD_STORE_DIR)/$(pass_namespace)/.gpg-id"
	if [ -f "$$gpg_id_file" ]; then
	  got=$$(tr -d '[:space:]' < "$$gpg_id_file")
	  if [ "$$got" = "$(pass_gpg_id)" ]; then
	    echo "$(green)OK  $(reset).gpg-id = $(pass_gpg_id)"
	  else
	    echo "$(yellow)WARN$(reset) .gpg-id is $$got (expected $(pass_gpg_id))"
	  fi
	else
	  echo "$(yellow)WARN$(reset) missing $$gpg_id_file — run: pass init -p $(pass_namespace) $(pass_gpg_id)"
	fi
	missing=0
	for k in LOGFIRE_READ_TOKEN ANTHROPIC_API_KEY FIRECRAWL_API_KEY GOOGLE_APPLICATION_CREDENTIALS; do
	  if pass show "$(pass_namespace)/$$k" >/dev/null 2>&1; then
	    echo "$(green)OK  $(reset)$(pass_namespace)/$$k"
	  else
	    echo "$(yellow)MISS$(reset) $(pass_namespace)/$$k"
	    missing=$$((missing + 1))
	  fi
	done
	# Shared Grok key (outside pass_namespace) — mailpilot_crm → xai_api_key
	if pass show grok/GROK_API_KEY >/dev/null 2>&1; then
	  echo "$(green)OK  $(reset)grok/GROK_API_KEY"
	else
	  echo "$(yellow)MISS$(reset) grok/GROK_API_KEY"
	  missing=$$((missing + 1))
	fi
	if [ "$(STRICT)" = "1" ] && [ "$$missing" -gt 0 ]; then
	  echo "$(yellow)$$missing key(s) missing (STRICT=1)$(reset)"
	  exit 1
	fi

deps:
	cd ansible
	ansible-galaxy collection install -r requirements.yml --upgrade

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
# Cross-cutting Linux roles (kronos host + mailpilot guests)
###############################################################################

# Untagged limit: the linux_unattended_upgrades tag runs in both the kronos and
# the mailpilot config plays, so this applies to every Linux instance at once.
linux-unattended-upgrades: ## automatic apt upgrades + auto-reboot on all Linux instances
	$(call tags,linux_unattended_upgrades)

linux-uv: ## install uv (astral) OS-global on all Linux instances
	$(call tags,linux_uv)

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
	$(call status_check,acu,22 80)

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
	$(load_secrets)
	$(call header,Deploy mailpilot-crm==$$v)
	$(PLAYBOOK) --tags mailpilot_crm $(LIMIT_ARG) --extra-vars "$$extra_vars mailpilot_version=$$v"

mailpilot-status: ## mailpilot VM reachability — SSH (22) port check
	$(call status_check,mailpilot,22)

# Static probe (no guest): unit StartLimit policy + migrate-before-restart task order.
# Lab: start unit against a pending-schema DB → expect failed, not a green crash loop.
mailpilot-unit-check: ## offline probe — unit StartLimit + db migrate before start
	bash scripts/check-mailpilot-unit.sh

# Single-role convenience targets for the mailpilot guests (secrets threaded).
# The tag is the target name with hyphens flipped to underscores, matching the
# role/tag names in site.yml:
#   gmake mailpilot-tools | mailpilot-postgresql | mailpilot-nodejs |
#        mailpilot-github-cli | mailpilot-google-cli |
#        mailpilot-claude-code | mailpilot-firecrawl-cli   [LIMIT=mailpilot-1]
mailpilot-tools mailpilot-postgresql mailpilot-nodejs mailpilot-github-cli mailpilot-google-cli mailpilot-claude-code mailpilot-firecrawl-cli:
	cd ansible
	$(load_secrets)
	$(PLAYBOOK) --tags $(subst -,_,$@) $(LIMIT_ARG) --extra-vars "$$extra_vars"

###############################################################################
# Release
###############################################################################

# `gmake release <part>` passes the part as an extra goal; pick it out and give
# the part words no-op recipes so make does not try to build them. There is no
# version manifest in this repo — the version lives in the git tag, and the next
# one is bumped from the latest `v*` tag.
part := $(word 1,$(filter major minor patch,$(MAKECMDGOALS)))

release: ## tag + publish a GitHub release (gmake release major|minor|patch)
	set -e
	test -n "$(part)" || { echo "usage: gmake release major|minor|patch"; exit 1; }
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
