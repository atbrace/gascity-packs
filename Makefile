GC ?= gc
PYTHON ?= python3
REGISTRY ?= registry.toml
REGISTRY_REF ?= main
REGISTRY_COMMIT ?= HEAD
REGISTRY_SOURCE_BASE ?= https://github.com/gastownhall/gascity-packs/tree/main

PACK_PATH ?= $(PACK)
SOURCE ?= .
CATALOG_SOURCE ?= $(REGISTRY_SOURCE_BASE)/$(PACK_PATH)

STAMP_PACK_DESCRIPTION :=
ifneq ($(strip $(PACK_DESCRIPTION)),)
STAMP_PACK_DESCRIPTION := --pack-description "$(PACK_DESCRIPTION)"
endif

.PHONY: registry-help registry-format-validate registry-validate registry-validate-all registry-drift registry-publish registry-withdraw

registry-help:
	@printf '%s\n' 'Registry targets:'
	@printf '%s\n' '  make registry-format-validate'
	@printf '%s\n' '  make registry-validate GC=/path/to/gc'
	@printf '%s\n' '  make registry-validate-all GC=/path/to/gc'
	@printf '%s\n' '  make registry-drift [CITY=/path/to/city] [CHANGED_SINCE=origin/main]'
	@printf '%s\n' '  make registry-publish GC=/path/to/gc PACK=<name> VERSION=<semver> DESCRIPTION="..." [PACK_PATH=<path>] [PACK_DESCRIPTION="..."]'
	@printf '%s\n' '  make registry-withdraw PACK=<name> VERSION=<semver> REASON="..."'

registry-format-validate:
	$(PYTHON) validate_registry.py $(REGISTRY)

registry-validate:
	$(GC) pack release validate $(REGISTRY)

registry-validate-all:
	$(GC) pack release validate $(REGISTRY) --include-withdrawn

# Report packs whose content has moved past their published release, plus (with
# CITY=) a city whose import pins or formula overrides shadow newer pack bytes.
# CHANGED_SINCE= restricts fatal findings to packs touched since that ref.
registry-drift:
	$(PYTHON) scripts/pack_drift_check.py \
		--registry $(REGISTRY) \
		$(if $(strip $(CHANGED_SINCE)),--changed-since $(CHANGED_SINCE),) \
		$(if $(strip $(CITY)),--city $(CITY),)

registry-publish:
	@test -n "$(PACK)" || { echo "PACK is required"; exit 2; }
	@test -n "$(PACK_PATH)" || { echo "PACK_PATH is required"; exit 2; }
	@test -n "$(VERSION)" || { echo "VERSION is required"; exit 2; }
	@test -n "$(DESCRIPTION)" || { echo "DESCRIPTION is required"; exit 2; }
	$(GC) pack release stamp $(REGISTRY) "$(PACK)" \
		--version "$(VERSION)" \
		--ref "$(REGISTRY_REF)" \
		--commit "$(REGISTRY_COMMIT)" \
		--description "$(DESCRIPTION)" \
		--source "$(SOURCE)" \
		--path "$(PACK_PATH)" \
		$(STAMP_PACK_DESCRIPTION)
	$(PYTHON) scripts/registry_release.py set-source \
		--registry "$(REGISTRY)" \
		--pack "$(PACK)" \
		--source "$(CATALOG_SOURCE)"

registry-withdraw:
	@test -n "$(PACK)" || { echo "PACK is required"; exit 2; }
	@test -n "$(VERSION)" || { echo "VERSION is required"; exit 2; }
	@test -n "$(REASON)" || { echo "REASON is required"; exit 2; }
	$(PYTHON) scripts/registry_release.py withdraw \
		--registry "$(REGISTRY)" \
		--pack "$(PACK)" \
		--version "$(VERSION)" \
		--reason "$(REASON)"
