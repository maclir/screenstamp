SHELL := /bin/zsh
.DEFAULT_GOAL := help

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
BREW ?= brew
DISPLAYPLACER ?= displayplacer

ACTION := $(firstword $(MAKECMDGOALS))
POSITIONAL_NAME := $(word 2,$(MAKECMDGOALS))
POSITIONAL_GOALS := $(wordlist 2,999,$(MAKECMDGOALS))
PROFILE_NAME := $(strip $(if $(NAME),$(NAME),$(POSITIONAL_NAME)))

ifneq ($(filter save load,$(ACTION)),)
.PHONY: $(POSITIONAL_GOALS)
endif

.PHONY: help install save load list test

help:
	@echo "Screenstamp — portable display layouts for macOS"
	@echo
	@echo "  make install           Install displayplacer and screenstamp"
	@echo "  make save office       Save the current layout as 'office'"
	@echo "  make load office       Apply 'office' to the connected displays"
	@echo "  make save NAME=office  Equivalent variable-based form"
	@echo "  make load NAME=office  Equivalent variable-based form"
	@echo "  make list              List saved profiles"
	@echo "  make test              Run the full test suite"

install:
	@if ! command -v "$(DISPLAYPLACER)" >/dev/null 2>&1; then \
		if ! command -v "$(BREW)" >/dev/null 2>&1; then \
			echo "Homebrew is required to install displayplacer: https://brew.sh" >&2; \
			exit 1; \
		fi; \
		echo "Installing required dependency: displayplacer"; \
		"$(BREW)" install displayplacer; \
	fi
	@install -d "$(DESTDIR)$(BINDIR)"
	@install -m 755 ./bin/screenstamp "$(DESTDIR)$(BINDIR)/screenstamp"
	@echo
	@echo "Screenstamp is ready:"
	@echo "  screenstamp save office"
	@echo "  screenstamp load office"

save:
	@$(call validate_profile_invocation)
	@./bin/screenstamp save "$(PROFILE_NAME)"

load:
	@$(call validate_profile_invocation)
	@./bin/screenstamp load "$(PROFILE_NAME)"

list:
	@./bin/screenstamp list


define validate_profile_invocation
	if [[ -z "$(NAME)" && "$(words $(POSITIONAL_GOALS))" -ne 1 ]]; then \
		echo "Usage: make $(ACTION) <name> (or make $(ACTION) NAME=<name>)" >&2; \
		exit 2; \
	fi; \
	if [[ -n "$(NAME)" && "$(words $(POSITIONAL_GOALS))" -ne 0 ]]; then \
		echo "Use either a positional name or NAME=<name>, not both." >&2; \
		exit 2; \
	fi
endef

test:
	@./tests/run

%:
	@if [[ "$(ACTION)" != "save" && "$(ACTION)" != "load" ]]; then \
		echo "Unknown target: $@" >&2; \
		exit 2; \
	fi
