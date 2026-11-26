unexport BASH_ENV
.PHONY: test lint install uninstall help

help:
	@echo "Targets:"
	@echo "  make test       Run syntax checks and automated test suite"
	@echo "  make lint       Run bash -n, shellcheck (if installed), and Python py_compile"
	@echo "  make install    Install colabd to ~/.local/bin/colabd"
	@echo "  make uninstall  Remove colabd installation"

lint:
	bash -n bin/colabd lib/*.sh scripts/*.sh tests/*.sh
	python3 -m py_compile lib/*.py
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x bin/colabd scripts/*.sh tests/*.sh; \
	else \
		echo "shellcheck not installed, skipped."; \
	fi

test:
	bash ./tests/run_tests.sh

install:
	bash ./scripts/install.sh

uninstall:
	bash ./scripts/uninstall.sh
