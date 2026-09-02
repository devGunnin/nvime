.PHONY: e2e e2e-one

# The live end-to-end scenarios. Real Neovim, real `claude` CLI, real money:
# see the "End-to-end scenarios" section of the README before running them.
e2e:
	tests/e2e/run.sh

# make e2e-one SCENARIO=cold-start
e2e-one:
	@test -n "$(SCENARIO)" || { echo 'usage: make e2e-one SCENARIO=<name> (tests/e2e/run.sh --list)'; exit 2; }
	tests/e2e/run.sh $(SCENARIO)
