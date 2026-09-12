ODIN ?= odin
CC ?= cc
CLANG ?= clang
BUILD := build
BOR := $(BUILD)/bor
DIRECT_C := $(BUILD)/direct-melodica.c
MIR_C := $(BUILD)/mir-melodica.c
MIR_DUMP := $(BUILD)/melodica.mir
CFLAGS_STRICT := -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3

.PHONY: all bor emit dump test bench clean

all: test

$(BUILD):
	mkdir -p $(BUILD)

bor: $(BOR)

$(BOR): src/*.odin | $(BUILD)
	$(ODIN) build src -out:$(BOR) -o:speed

emit: $(DIRECT_C) $(MIR_C)

dump: $(MIR_DUMP)

$(DIRECT_C): $(BOR) test/melodica/main.odin
	$(BOR) emit-c-direct test/melodica -o $@

$(MIR_C): $(BOR) test/melodica/main.odin
	$(BOR) emit-c-mir test/melodica -o $@

$(MIR_DUMP): $(BOR) test/melodica/main.odin
	$(BOR) dump-mir test/melodica -o $@

$(BUILD)/smoke-direct-gcc: $(DIRECT_C) test/c99/smoke.c
	$(CC) $(CFLAGS_STRICT) $(DIRECT_C) test/c99/smoke.c -o $@

$(BUILD)/smoke-direct-clang: $(DIRECT_C) test/c99/smoke.c
	$(CLANG) $(CFLAGS_STRICT) $(DIRECT_C) test/c99/smoke.c -o $@

$(BUILD)/smoke-mir-gcc: $(MIR_C) test/c99/smoke.c
	$(CC) $(CFLAGS_STRICT) $(MIR_C) test/c99/smoke.c -o $@

$(BUILD)/smoke-mir-clang: $(MIR_C) test/c99/smoke.c
	$(CLANG) $(CFLAGS_STRICT) $(MIR_C) test/c99/smoke.c -o $@

$(BUILD)/native-melodica.a: test/melodica/main.odin | $(BUILD)
	$(ODIN) build test/melodica -build-mode:static -out:$@ -o:speed -reloc-mode:pic -no-entry-point

$(BUILD)/smoke-native: $(BUILD)/native-melodica.a test/c99/smoke.c
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 test/c99/smoke.c $(BUILD)/native-melodica.a -lm -ldl -lpthread -o $@

test: $(BUILD)/smoke-direct-gcc $(BUILD)/smoke-direct-clang $(BUILD)/smoke-mir-gcc $(BUILD)/smoke-mir-clang $(BUILD)/smoke-native $(MIR_DUMP)
	./$(BUILD)/smoke-direct-gcc
	./$(BUILD)/smoke-direct-clang
	./$(BUILD)/smoke-mir-gcc
	./$(BUILD)/smoke-mir-clang
	./$(BUILD)/smoke-native
	test -s $(MIR_DUMP)
	grep -q 'jump_if_false' $(MIR_DUMP)
	grep -q 'binary' $(MIR_DUMP)
	grep -q 'return' $(MIR_DUMP)
	@echo 'Bor: direct C99, flat MIR C99, MIR dump, and native Odin behavior agree'

$(BUILD)/bench-direct-gcc: $(DIRECT_C) test/c99/bench.c
	$(CC) $(CFLAGS_STRICT) $(DIRECT_C) test/c99/bench.c -o $@

$(BUILD)/bench-direct-clang: $(DIRECT_C) test/c99/bench.c
	$(CLANG) $(CFLAGS_STRICT) $(DIRECT_C) test/c99/bench.c -o $@

$(BUILD)/bench-mir-gcc: $(MIR_C) test/c99/bench.c
	$(CC) $(CFLAGS_STRICT) $(MIR_C) test/c99/bench.c -o $@

$(BUILD)/bench-mir-clang: $(MIR_C) test/c99/bench.c
	$(CLANG) $(CFLAGS_STRICT) $(MIR_C) test/c99/bench.c -o $@

$(BUILD)/bench-native: $(BUILD)/native-melodica.a test/c99/bench.c
	$(CC) -std=c11 -Wall -Wextra -Werror -O3 test/c99/bench.c $(BUILD)/native-melodica.a -lm -ldl -lpthread -o $@

bench: $(BUILD)/bench-direct-gcc $(BUILD)/bench-direct-clang $(BUILD)/bench-mir-gcc $(BUILD)/bench-mir-clang $(BUILD)/bench-native
	@echo '=== Bor direct / GCC ==='
	./$(BUILD)/bench-direct-gcc
	@echo '=== Bor MIR / GCC ==='
	./$(BUILD)/bench-mir-gcc
	@echo '=== Bor direct / Clang ==='
	./$(BUILD)/bench-direct-clang
	@echo '=== Bor MIR / Clang ==='
	./$(BUILD)/bench-mir-clang
	@echo '=== native Odin ==='
	./$(BUILD)/bench-native

clean:
	rm -rf $(BUILD)
