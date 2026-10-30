# OpenTTD-Max build. Targets:
#   make            validate data, compile max-air.grf and max-rail.grf, bundle the MaxTransit AIs
#   make render     render every model with Blender (needs BPY_PYTHON, see tools/render.py)
#   make gfx        post-process build/render into gfx/ sprite sheets
#   make placeholder regenerate the placeholder sprites used for vehicles without art
#   make sounds     synthesise sounds/*.wav (tools/make_sounds.py)
#   make test-grf   build without badges for OpenTTD < 15 (used by tools/ingame)
#   make bundle     BaNaNaS-style tar files in build/bundle/ (VERSION_LABEL=0.1.0-alpha)
#   make ai-bundle  the AIs (MaxTransit, MaxTransit2, MaxTycoon) as BaNaNaS-style tars in build/bundle/; AI=<name> for one
#   make ai-test    a 5-year headless game with the AI (needs the OpenTTD build from tools/ingame)
#   make ai2-test   the same with MaxTransit2 (on macOS the Steam build of OpenTTD is used when present)
#   make tycoon-test the same with MaxTycoon (docs/TYCOON.md)
#   make clean
PY         ?= python3
BPY_PYTHON ?= /opt/bpyvenv/bin/python
NMLC       ?= nmlc
NMLFLAGS   ?= -c -l build/lang
GEN_FLAGS  ?=

GRFS   = max-air.grf max-rail.grf
INPUTS = $(wildcard data/*.csv) $(wildcard src/*.pnml) $(wildcard src/common/*.pnml) $(wildcard lang/*.lng) \
         $(wildcard gfx/*/*/manifest.json) $(wildcard sounds/*.wav) tools/gen_nml.py VERSION

.PHONY: all check nml grf render gfx placeholder sounds test-grf bundle ai-bundle ai-test ai2-test tycoon-test clean

all: check grf ai-bundle

check:
	$(PY) tools/validate.py

build/.nml-stamp: $(INPUTS)
	$(PY) tools/gen_nml.py $(GEN_FLAGS)
	@touch $@

nml: build/.nml-stamp

max-air.grf: build/.nml-stamp
	$(NMLC) $(NMLFLAGS) --grf $@ build/max-air.nml

max-rail.grf: build/.nml-stamp
	$(NMLC) $(NMLFLAGS) --grf $@ build/max-rail.nml

grf: $(GRFS)

render:
	$(BPY_PYTHON) tools/render.py --all

gfx:
	$(PY) tools/postprocess.py --all

placeholder:
	$(PY) tools/make_placeholder_gfx.py

sounds:
	$(PY) tools/make_sounds.py

# Badge-free build for OpenTTD 13/14 test installs; output goes to build/test/.
test-grf:
	$(PY) tools/gen_nml.py --no-badges
	@mkdir -p build/test
	$(NMLC) $(NMLFLAGS) --grf build/test/max-air.grf build/max-air.nml
	$(NMLC) $(NMLFLAGS) --grf build/test/max-rail.grf build/max-rail.nml
	@rm -f build/.nml-stamp

bundle: grf
	$(PY) tools/bundle.py $(if $(VERSION_LABEL),--version $(VERSION_LABEL),)

AI ?=

ai-bundle:
	$(PY) tools/bundle.py --ai $(if $(AI),--name $(AI),) $(if $(VERSION_LABEL),--version $(VERSION_LABEL),)

ai-test:
	$(PY) tools/ai/run_ai.py --ai $(or $(AI),MaxTransit) --years 5

ai2-test:
	$(PY) tools/ai/run_ai.py --ai MaxTransit2 --years 5 --industries 4

tycoon-test:
	$(PY) tools/ai/run_ai.py --ai MaxTycoon --years 5 --industries 4

clean:
	rm -rf build $(GRFS) .nmlcache
