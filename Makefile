# Local runs of digitalutsc/reusable_workflows' GitHub Actions CI.
# `make help` lists the targets; README.md explains them.

# Optional settings file (copy config.mk.example). Values given on the command
# line (make X=...) still override it.
-include config.mk

REUSABLE_REPO ?= https://github.com/digitalutsc/reusable_workflows.git
REUSABLE_REF  ?= omarhxk-patch-1
REUSABLE_DIR  ?= reusable_workflows
MODULES       ?=
SITE          ?= stories
MODULE_DIR    ?=
MODULE        ?=
DRUPAL        ?= 10.6 11.3
PHP           ?= 8.3 8.4
JOBS          ?= 4
COMPOSER_CACHE_VOLUME ?= lga-composer-cache
ACTIONLINT_IMAGE ?= rhysd/actionlint:1.7.7

export REUSABLE_DIR SITE DRUPAL PHP JOBS COMPOSER_CACHE_VOLUME

# What the test targets run on: MODULE_DIR (any directories) if set, else
# MODULES (names under modules/), else every module under modules/.
TARGET_DIRS = $(or $(MODULE_DIR),$(addprefix modules/,$(MODULES)))

.PHONY: help config reusable check-reusable modules test test-act test-direct report lint inspect ci ci-dry act-selftest act-module clean

help: ## List targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

config: ## Show the settings in effect (config.mk + command line)
	@echo "REUSABLE_REPO = $(REUSABLE_REPO)"
	@echo "REUSABLE_REF  = $(REUSABLE_REF)"
	@echo "REUSABLE_DIR  = $(REUSABLE_DIR) (checked out: $$(git -C "$(REUSABLE_DIR)" rev-parse --abbrev-ref HEAD 2>/dev/null || echo none) $$(git -C "$(REUSABLE_DIR)" rev-parse --short HEAD 2>/dev/null))"
	@echo "MODULES       = $(or $(MODULES),(all))"
	@echo "SITE          = $(SITE)"
	@echo "DRUPAL / PHP  = $(DRUPAL) / $(PHP)   JOBS = $(JOBS)"
	@echo "config.mk     = $$([ -f config.mk ] && echo present || echo 'absent (defaults)')"

reusable: ## Clone/update REUSABLE_REPO at REUSABLE_REF (branch, tag or commit) into REUSABLE_DIR
	@if [ -d "$(REUSABLE_DIR)/.git" ]; then \
	  git -C "$(REUSABLE_DIR)" fetch -q origin "$(REUSABLE_REF)" && \
	  git -C "$(REUSABLE_DIR)" checkout -q -B "$(REUSABLE_REF)" FETCH_HEAD; \
	else \
	  git clone -q "$(REUSABLE_REPO)" "$(REUSABLE_DIR)" && \
	  git -C "$(REUSABLE_DIR)" fetch -q origin "$(REUSABLE_REF)" && \
	  git -C "$(REUSABLE_DIR)" checkout -q -B "$(REUSABLE_REF)" FETCH_HEAD; \
	fi
	@echo "$(REUSABLE_DIR): $$(git -C "$(REUSABLE_DIR)" log --oneline -1) [$(REUSABLE_REF)]"

# Refuses to test a checkout that isn't REUSABLE_REF (e.g. after editing
# config.mk without re-running make reusable).
check-reusable:
	@cur=$$(git -C "$(REUSABLE_DIR)" rev-parse --abbrev-ref HEAD 2>/dev/null) || { echo "No $(REUSABLE_DIR): run make reusable"; exit 2; }; \
	[ "$$cur" = "$(REUSABLE_REF)" ] || { echo "$(REUSABLE_DIR) is at $$cur, REUSABLE_REF is $(REUSABLE_REF): run make reusable"; exit 2; }

modules: ## Copy MODULES (default: every module that calls reusable_workflows) out of the replica SITE into modules/
	./fetch-modules.sh $(MODULES)

test: test-act test-direct ## Both passes

test-act: check-reusable ## Pass A: each module's own ci.yml through act, against REUSABLE_DIR
	./run-act-all.sh $(TARGET_DIRS)

test-direct: ## Pass B: the workflow's PHPUnit container directly, JOBS at a time
	./run-direct-all.sh $(TARGET_DIRS)

report: ## Show the newest report of each pass
	@for p in act direct; do f=$$(ls -t results/$$p-*.md 2>/dev/null | head -1); [ -n "$$f" ] && { echo "== $$f"; sed -n '1,12p' "$$f"; echo; }; done; true

lint: ## actionlint the workflows in REUSABLE_DIR (or MODULE_DIR if set)
	docker run --rm -v "$(abspath $(or $(MODULE_DIR),$(REUSABLE_DIR))):/repo" -w /repo $(ACTIONLINT_IMAGE) -color

inspect: ## Show the CI image's entrypoint and installed Drupal packages (first of DRUPAL/PHP)
	./inspect-image.sh -d $(firstword $(DRUPAL)) -p $(firstword $(PHP))

ci: ## One module, the PHPUnit container directly (MODULE_DIR=, DRUPAL, PHP, CHROMEDRIVER=1, MODULE=machine name)
	@test -n "$(MODULE_DIR)" || { echo "set MODULE_DIR=<module checkout>"; exit 2; }
	./run-module-ci.sh -d "$(DRUPAL)" -p "$(PHP)" $(if $(MODULE),-m $(MODULE)) $(if $(CHROMEDRIVER),-c) "$(MODULE_DIR)"

ci-dry: ## Print the docker commands `make ci` would run
	@test -n "$(MODULE_DIR)" || { echo "set MODULE_DIR=<module checkout>"; exit 2; }
	./run-module-ci.sh -n -d "$(DRUPAL)" -p "$(PHP)" $(if $(MODULE),-m $(MODULE)) $(if $(CHROMEDRIVER),-c) "$(MODULE_DIR)"

act-selftest: check-reusable ## reusable_workflows' own testing.yml with act
	./run-act.sh selftest

act-module: check-reusable ## One module's ci.yml with act, all combinations in one run (MODULE_DIR=)
	@test -n "$(MODULE_DIR)" || { echo "set MODULE_DIR=<module checkout>"; exit 2; }
	./run-act.sh module "$(MODULE_DIR)"

clean: ## Remove logs/, results/, modules/ and leftover containers/networks (keeps REUSABLE_DIR, config.mk, cache volume)
	rm -rf logs results modules
	-docker ps -aq --filter 'name=^lga-' | xargs docker rm -f 2>/dev/null
	-docker network ls -q --filter 'name=^lga-' | xargs docker network rm 2>/dev/null
	-docker rm -f drupal chromedriver 2>/dev/null
	-docker network rm ci-default 2>/dev/null
	-docker ps -aq --filter 'name=^act-' | xargs docker rm -f 2>/dev/null
