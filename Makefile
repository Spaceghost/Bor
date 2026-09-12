ODIN ?= odin
PYTHON ?= python3
BUILD ?= build
BOR := $(abspath $(BUILD)/bor)
CODIN ?= $(abspath $(BUILD)/references/codin/codin)
THOR ?= $(abspath $(BUILD)/references/Thor/thor)
ROUNDS ?= 7

.PHONY: all test unit semantics generated rejection shootout references cross clean demo
all: $(BOR)
$(BOR): $(wildcard src/*.odin)
	mkdir -p $(BUILD)
	$(ODIN) build src -o:speed -out:$@
unit:
	mkdir -p $(BUILD)
	$(ODIN) test src -o:speed -out:$(BUILD)/unit-tests -define:ODIN_TEST_RANDOM_SEED=45175
semantics: $(BOR)
	$(PYTHON) tools/test_semantics.py --odin "$(ODIN)" --bor "$(BOR)" --out "$(abspath $(BUILD)/semantics)"
generated: $(BOR)
	$(PYTHON) tools/test_generated.py --odin "$(ODIN)" --bor "$(BOR)" --out "$(abspath $(BUILD)/generated)"
rejection: $(BOR)
	$(PYTHON) tools/test_rejection.py --odin "$(ODIN)" --bor "$(BOR)" --out "$(abspath $(BUILD)/rejection)"
test: unit semantics generated rejection
references:
	sh tools/setup-references.sh "$(abspath $(BUILD)/references)"
shootout: $(BOR)
	$(PYTHON) tools/shootout.py --odin "$(ODIN)" --bor "$(BOR)" --codin "$(CODIN)" --thor "$(THOR)" --rounds "$(ROUNDS)" --out "$(abspath $(BUILD)/shootout)"
cross: $(BOR)
	$(PYTHON) tools/test_cross.py --bor "$(BOR)" --out "$(abspath $(BUILD)/cross)"
demo: $(BOR)
	$(BOR) eval tests/semantics --entry sum_upto --arg 10
clean:
	rm -rf -- "$(BUILD)"
