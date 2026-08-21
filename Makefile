# Clever Cloud "linux" runtime entrypoint.
# The platform resolves the run command from this Makefile's `run:` target
# (unless CC_RUN_COMMAND is set, which takes precedence).

.PHONY: run
run:
	@bash ./boot.sh
