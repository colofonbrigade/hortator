.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e

MIX ?= mix

help:
	@echo "Targets: setup, deps, build, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) escript.build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

# Live end-to-end: creates a disposable issue in your test Linear project
# (LINEAR_TEST_PROJECT_SLUG), runs a real Claude Code session against it,
# and verifies the work. Requires LINEAR_API_KEY and LINEAR_TEST_PROJECT_SLUG
# to be set. Not part of `make all` — run explicitly.
e2e:
	HORTATOR_RUN_LIVE_E2E=1 $(MIX) test test/core/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
