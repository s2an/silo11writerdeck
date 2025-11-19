# File: Makefile
SHELL    := /bin/bash
VENV_DIR := .venv
PYTHON   := python3
PIP      := $(VENV_DIR)/bin/pip
PYTEST   := $(VENV_DIR)/bin/pytest

.PHONY: venv install test clean shell

# Create a virtual environment if it doesn't exist
venv:
	@test -d $(VENV_DIR) || $(PYTHON) -m venv $(VENV_DIR)

# Install or update dependencies (pytest for now)
install: venv
	$(PIP) install pytest

# Run tests
test: install
	$(PYTEST) -q

# Open a subshell with the venv activated (POSIX-safe; no process substitution)
shell: install
	@echo "Spawning subshell with venv activated. Type 'exit' to leave."
	@tmp_rcfile="$$(mktemp)"; \
	echo ". $(VENV_DIR)/bin/activate" > $$tmp_rcfile; \
	bash --rcfile $$tmp_rcfile; \
	rm -f $$tmp_rcfile

# Remove venv and caches
clean:
	rm -rf $(VENV_DIR) .pytest_cache **/__pycache__
