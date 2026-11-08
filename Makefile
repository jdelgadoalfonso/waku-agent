# waku-agent — one command per pillar.
#
# Make is not a framework — it's a 45-year-old command shortcut tool that
# ships with every Mac/Linux. Each target below is just the shell command
# you'd otherwise type.
#
# Waku ships as one Nim binary. `make nim-build` builds it and `make nim-test`
# runs its offline suite; those two are the front door. The targets below them
# drive the frozen Python half in `waku/`, which still runs and still guards
# the repo (see AGENTS.md for why it stays in the tree).
#
# PY picks the project venv automatically so you never need to remember
# `source .venv/bin/activate` — both work, this is just fewer steps.
PY := $(shell [ -x .venv/bin/python ] && echo .venv/bin/python || echo python)

# Maintainers work on the repo's own .waku, never on the ~/.waku a person's
# real assistant uses (spec 002). An explicit WAKU_HOME still wins.
export WAKU_HOME ?= $(CURDIR)/.waku

.PHONY: run voice telegram discord brief dashboard trace eval eval-judge gate lint
.PHONY: run voice telegram whatsapp brief dashboard trace eval eval-judge gate lint nim-test nim-build
.PHONY: nim-build-tls nim-test-tls

run:            ## chat with Waku in the terminal (the frozen Python half)
	$(PY) -m waku

voice:          ## talk to it — push-to-talk, or always-on with WAKU_WAKE_WORD
	$(PY) -m waku voice

telegram:       ## phone → laptop (needs TELEGRAM_BOT_TOKEN in .env)
	$(PY) -m waku telegram

discord:        ## Discord → laptop (needs DISCORD_BOT_TOKEN in .env)
	$(PY) -m waku discord
whatsapp:       ## WhatsApp → laptop (needs WHATSAPP_TOKEN in .env, public URL)
	$(PY) -m waku whatsapp

brief:          ## morning briefing from calendar + mail + memory (as a LOOP)
	$(PY) -m waku brief

gather:         ## same job as a GRAPH: 4 sources in parallel, then one digest
	$(PY) -m waku gather

# The server holds dashboard.py in memory: static JS/CSS reload on refresh, but
# Python routes do NOT. After pulling a change that touches dashboard.py (or any
# imported module), stop this and re-run it, or the UI shows stale backend data.
dashboard:      ## everything on one page — http://localhost:7777 (restart after a backend pull)
	$(PY) -m waku.ops.dashboard

trace:          ## deep trace waterfalls (Phoenix) at http://localhost:6006
	$(PY) -m phoenix.server.main serve

eval:           ## deterministic evals of the frozen Python half (0/1, no judge involved)
	$(PY) -m pytest -q evals/deterministic

eval-judge:     ## LLM-as-judge evals (scored %, needs an API key)
	$(PY) -m pytest -q evals/judge

gate:           ## the release gate: deterministic must pass, judge must clear threshold
	$(PY) -m waku.ops.release_gate

shootout:       ## same tasks, different brains: make shootout RUNS="kimi:kimi-k3 anthropic:claude-opus-4-8"
	$(PY) scripts/shootout.py $(RUNS)

shootout-coding: ## coding round via pi, scored by tests: make shootout-coding RUNS="kimi:kimi-k3 anthropic:claude-opus-4-8"
	$(PY) scripts/shootout.py $(RUNS) --coding

lint:
	$(PY) -m ruff check waku evals scripts hosted

# The Nim port builds on its own: stdlib plus db_connector plus mandatory mimalloc_nim,
# from pyproject.toml. Both targets `cd nim` first because the suite's pins
# read the checkout relative to the working directory (tests/test_cli.nim
# walks up to data/providers.toml), so what runs here is the command a person
# would type from nim/ themselves. These are the front door: the binary is how
# a person uses Waku.
nim-test:       ## the Nim port's offline suite (every tests/test_*.nim, no API key)
	cd nim && nimble test

nim-build:      ## the one Nim binary (needs the checkout: the dashboard assets embed at compile time)
	cd nim && nimble -d:release -d:useMimalloc -d:ssl -d:wakuTls -d:wakuStyle --path:vendor/terminal_style build

# The same two targets with the live-TLS switches, and for the same
# reason they `cd nim`: the suite's pins read the checkout relative to
# the working directory. The switches are NOT spelled out here — they
# live in `nim/waku.nimble`'s `buildTls`/`testTls` tasks, so the
# Makefile, CI and a developer cannot disagree about them. Both write
# their own binary (`waku_tls`, `test_tls_flagged`) and never touch the
# default build's outputs.
#
# Needs the OpenSSL development headers (`libssl-dev` on Debian and
# Ubuntu); `nim-test` does not, which is the point of keeping the flag
# off its suite. `nim-build` above carries the live switches, so it
# needs them too.
nim-build-tls:  ## the same binary with live TLS (wss gateway, https REST)
	cd nim && nimble buildTls

nim-test-tls:   ## the live-TLS pins, offline, in the flagged build
	cd nim && nimble testTls
