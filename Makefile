ODIN ?= odin
CC ?= cc
CLANG ?= clang
BUILD := build
BOR := $(BUILD)/bor
DIRECT_C := $(BUILD)/direct-melodica.c
MIR_C := $(BUILD)/mir-melodica.c
LINKAGE_DIRECT_C := $(BUILD)/direct-linkage.c
LINKAGE_MIR_C := $(BUILD)/mir-linkage.c
CONTROL_DIRECT_C := $(BUILD)/direct-control.c
CONTROL_MIR_C := $(BUILD)/mir-control.c

.PHONY: all bor emit test clean

all: test

$(BUILD):
	mkdir -p $(BUILD)

bor: $(BOR)

$(BOR): src/*.odin | $(BUILD)
	$(ODIN) build src -out:$(BOR) -o:speed

emit: $(DIRECT_C) $(MIR_C) $(LINKAGE_DIRECT_C) $(LINKAGE_MIR_C) $(CONTROL_DIRECT_C) $(CONTROL_MIR_C)

$(DIRECT_C): $(BOR) test/melodica/main.odin
	$(BOR) emit-c-direct test/melodica -o $@

$(MIR_C): $(BOR) test/melodica/main.odin
	$(BOR) emit-c-mir test/melodica -o $@

$(LINKAGE_DIRECT_C): $(BOR) test/linkage/main.odin
	$(BOR) emit-c-direct test/linkage -o $@

$(LINKAGE_MIR_C): $(BOR) test/linkage/main.odin
	$(BOR) emit-c-mir test/linkage -o $@

$(CONTROL_DIRECT_C): $(BOR) test/control/main.odin
	$(BOR) emit-c-direct test/control -o $@

$(CONTROL_MIR_C): $(BOR) test/control/main.odin
	$(BOR) emit-c-mir test/control -o $@

$(BUILD)/smoke-direct-gcc: $(DIRECT_C) test/c99/smoke.c
	$(CC) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(DIRECT_C) test/c99/smoke.c -o $@

$(BUILD)/smoke-direct-clang: $(DIRECT_C) test/c99/smoke.c
	$(CLANG) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(DIRECT_C) test/c99/smoke.c -o $@

$(BUILD)/smoke-mir-gcc: $(MIR_C) test/c99/smoke.c
	$(CC) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(MIR_C) test/c99/smoke.c -o $@

$(BUILD)/smoke-mir-clang: $(MIR_C) test/c99/smoke.c
	$(CLANG) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(MIR_C) test/c99/smoke.c -o $@

$(BUILD)/linkage-direct-gcc: $(LINKAGE_DIRECT_C) test/c99/linkage_smoke.c
	$(CC) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(LINKAGE_DIRECT_C) test/c99/linkage_smoke.c -o $@

$(BUILD)/linkage-direct-clang: $(LINKAGE_DIRECT_C) test/c99/linkage_smoke.c
	$(CLANG) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(LINKAGE_DIRECT_C) test/c99/linkage_smoke.c -o $@

$(BUILD)/linkage-mir-gcc: $(LINKAGE_MIR_C) test/c99/linkage_smoke.c
	$(CC) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(LINKAGE_MIR_C) test/c99/linkage_smoke.c -o $@

$(BUILD)/linkage-mir-clang: $(LINKAGE_MIR_C) test/c99/linkage_smoke.c
	$(CLANG) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(LINKAGE_MIR_C) test/c99/linkage_smoke.c -o $@

$(BUILD)/control-direct-gcc: $(CONTROL_DIRECT_C) test/c99/control_smoke.c
	$(CC) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(CONTROL_DIRECT_C) test/c99/control_smoke.c -o $@

$(BUILD)/control-direct-clang: $(CONTROL_DIRECT_C) test/c99/control_smoke.c
	$(CLANG) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(CONTROL_DIRECT_C) test/c99/control_smoke.c -o $@

$(BUILD)/control-mir-gcc: $(CONTROL_MIR_C) test/c99/control_smoke.c
	$(CC) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(CONTROL_MIR_C) test/c99/control_smoke.c -o $@

$(BUILD)/control-mir-clang: $(CONTROL_MIR_C) test/c99/control_smoke.c
	$(CLANG) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(CONTROL_MIR_C) test/c99/control_smoke.c -o $@

$(BUILD)/native-melodica.a: test/melodica/main.odin | $(BUILD)
	$(ODIN) build test/melodica -build-mode:static -out:$@ -o:speed -reloc-mode:pic -no-entry-point

$(BUILD)/smoke-native: $(BUILD)/native-melodica.a test/c99/smoke.c
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 test/c99/smoke.c $(BUILD)/native-melodica.a -lm -ldl -lpthread -o $@

$(BUILD)/native-linkage.a: test/linkage/main.odin | $(BUILD)
	$(ODIN) build test/linkage -build-mode:static -out:$@ -o:speed -reloc-mode:pic -no-entry-point

$(BUILD)/linkage-native: $(BUILD)/native-linkage.a test/c99/linkage_smoke.c
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 test/c99/linkage_smoke.c $(BUILD)/native-linkage.a -lm -ldl -lpthread -o $@

$(BUILD)/native-control.a: test/control/main.odin | $(BUILD)
	$(ODIN) build test/control -build-mode:static -out:$@ -o:speed -reloc-mode:pic -no-entry-point

$(BUILD)/control-native: $(BUILD)/native-control.a test/c99/control_smoke.c
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 test/c99/control_smoke.c $(BUILD)/native-control.a -lm -ldl -lpthread -o $@

test: $(BUILD)/smoke-direct-gcc $(BUILD)/smoke-direct-clang $(BUILD)/smoke-mir-gcc $(BUILD)/smoke-mir-clang $(BUILD)/smoke-native $(BUILD)/linkage-direct-gcc $(BUILD)/linkage-direct-clang $(BUILD)/linkage-mir-gcc $(BUILD)/linkage-mir-clang $(BUILD)/linkage-native $(BUILD)/control-direct-gcc $(BUILD)/control-direct-clang $(BUILD)/control-mir-gcc $(BUILD)/control-mir-clang $(BUILD)/control-native
	./$(BUILD)/smoke-direct-gcc
	./$(BUILD)/smoke-direct-clang
	./$(BUILD)/smoke-mir-gcc
	./$(BUILD)/smoke-mir-clang
	./$(BUILD)/smoke-native
	./$(BUILD)/linkage-direct-gcc
	./$(BUILD)/linkage-direct-clang
	./$(BUILD)/linkage-mir-gcc
	./$(BUILD)/linkage-mir-clang
	./$(BUILD)/linkage-native
	./$(BUILD)/control-direct-gcc
	./$(BUILD)/control-direct-clang
	./$(BUILD)/control-mir-gcc
	./$(BUILD)/control-mir-clang
	./$(BUILD)/control-native
	@echo 'Bor: direct C99, flat MIR C99, and native Odin behavior agree'
	@echo 'Bor: calling convention and export linkage remain independent'
	@echo 'Bor: control-flow/operator workload agrees across both backends and native Odin'

clean:
	rm -rf $(BUILD)

.PHONY: unit audit benchmark
unit: | $(BUILD)
	$(ODIN) test src -out:$(BUILD)/unit -define:ODIN_TEST_THREADS=1

audit: bor
	ODIN="$(ODIN)" CC="$(CC)" CLANG="$(CLANG)" python3 tools/audit.py

benchmark: bor
	ODIN="$(ODIN)" CC="$(CC)" CLANG="$(CLANG)" python3 tools/benchmark.py $(BENCH_ARGS)

.PHONY: matrix benchmark-matrix
matrix benchmark-matrix: bor
	python3 -m unittest discover -s tools -p test_matrix.py
	ODIN="$(ODIN)" CC="$(CC)" CLANG="$(CLANG)" python3 tools/matrix.py $(MATRIX_ARGS)
