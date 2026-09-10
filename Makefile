SHELL := /bin/zsh
.DEFAULT_GOAL := help

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
BREW ?= brew
DISPLAYPLACER ?= displayplacer
SWIFTC ?= swiftc

ACTION := $(firstword $(MAKECMDGOALS))
POSITIONAL_NAME := $(word 2,$(MAKECMDGOALS))
POSITIONAL_GOALS := $(wordlist 2,999,$(MAKECMDGOALS))
PROFILE_NAME := $(strip $(if $(NAME),$(NAME),$(POSITIONAL_NAME)))

ifneq ($(filter save load save-apps load-apps apps save-displays load-displays displays,$(ACTION)),)
.PHONY: $(POSITIONAL_GOALS)
endif

.PHONY: help install save load save-displays load-displays displays save-apps load-apps apps permissions list test build-helper

help:
	@echo "Screenstamp — portable display layouts for macOS"
	@echo
	@echo "  make install               Install displayplacer and screenstamp"
	@echo "  make save office           Save current layout and app placements as 'office'"
	@echo "  make load office           Apply 'office' to connected displays and place apps"
	@echo "  make save-displays office  Save only display layout for 'office'"
	@echo "  make load-displays office  Apply only display layout for 'office' (without moving apps)"
	@echo "  make save-apps office      Save only app placements for 'office'"
	@echo "  make load-apps office      Restore only app placements for 'office'"
	@echo "  make permissions           Check/request required macOS Accessibility permissions"
	@echo "  make save NAME=office      Equivalent variable-based form"
	@echo "  make load NAME=office      Equivalent variable-based form"
	@echo "  make list                  List saved profiles"
	@echo "  make test                  Run the full test suite"

build-helper:
	@if command -v "$(SWIFTC)" >/dev/null 2>&1 && [ -f ./bin/screenstamp-app-helper.swift ]; then \
		"$(SWIFTC)" -O ./bin/screenstamp-app-helper.swift -o ./bin/screenstamp-app-helper 2>/dev/null || true; \
	fi

install: build-helper
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
	@if [ -f ./bin/screenstamp-app-helper ]; then \
		install -m 755 ./bin/screenstamp-app-helper "$(DESTDIR)$(BINDIR)/screenstamp-app-helper"; \
	fi
	@if [ -f ./bin/screenstamp-app-helper.swift ]; then \
		install -m 755 ./bin/screenstamp-app-helper.swift "$(DESTDIR)$(BINDIR)/screenstamp-app-helper.swift"; \
	fi
	@echo
	@echo "Screenstamp is ready:"
	@echo "  screenstamp save office"
	@echo "  screenstamp load office"
	@echo "  screenstamp save-displays office"
	@echo "  screenstamp load-displays office"
	@echo "  screenstamp save-apps office"
	@echo "  screenstamp load-apps office"
	@echo
	@echo "macOS Permissions:"
	@echo "  Run 'screenstamp permissions' or grant Accessibility permissions to your terminal"
	@echo "  under System Settings > Privacy & Security > Accessibility."

save:
	@$(call validate_profile_invocation)
	@./bin/screenstamp save "$(PROFILE_NAME)"

save-displays:
	@$(call validate_profile_invocation)
	@./bin/screenstamp save-displays "$(PROFILE_NAME)"

save-apps:
	@$(call validate_profile_invocation)
	@./bin/screenstamp save-apps "$(PROFILE_NAME)"

load:
	@$(call validate_profile_invocation)
	@./bin/screenstamp load "$(PROFILE_NAME)"

load-displays:
	@$(call validate_profile_invocation)
	@./bin/screenstamp load-displays "$(PROFILE_NAME)"

displays:
	@$(call validate_profile_invocation)
	@./bin/screenstamp load-displays "$(PROFILE_NAME)"

load-apps:
	@$(call validate_profile_invocation)
	@./bin/screenstamp load-apps "$(PROFILE_NAME)"

apps:
	@$(call validate_profile_invocation)
	@./bin/screenstamp load-apps "$(PROFILE_NAME)"

permissions:
	@./bin/screenstamp permissions

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
	@if [[ "$(ACTION)" != "save" && "$(ACTION)" != "load" && "$(ACTION)" != "save-apps" && "$(ACTION)" != "load-apps" && "$(ACTION)" != "apps" && "$(ACTION)" != "save-displays" && "$(ACTION)" != "load-displays" && "$(ACTION)" != "displays" ]]; then \
		echo "Unknown target: $@" >&2; \
		exit 2; \
	fi
