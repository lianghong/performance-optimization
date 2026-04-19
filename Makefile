SCRIPTS := system_optimize.sh network_optimize.sh

.PHONY: all lint syntax shellcheck bashate test check clean

all: check

## Run every gate (syntax, shellcheck, bashate, bats).
check: syntax shellcheck bashate test

## bash -n on both scripts.
syntax:
	@for s in $(SCRIPTS); do bash -n "$$s"; done
	@echo "syntax: OK"

shellcheck:
	@shellcheck -x $(SCRIPTS) lib/common.sh
	@echo "shellcheck: OK"

bashate:
	@bashate -i E006 $(SCRIPTS)
	@echo "bashate: OK"

## Run the bats test suite.
test:
	@bats tests/

lint: shellcheck bashate

clean:
	@rm -rf /tmp/system-optimize-sysctl.* 2>/dev/null || true
