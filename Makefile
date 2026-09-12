ODIN ?= odin
CC ?= cc
CLANG ?= clang
BUILD := build
BOR := $(BUILD)/bor
BOR_C := $(BUILD)/bor-melodica.c

.PHONY: all bor emit test clean

all: test

$(BUILD):
	mkdir -p $(BUILD)

bor: $(BOR)

$(BOR): src/main.odin | $(BUILD)
	$(ODIN) build src -out:$(BOR) -o:speed

emit: $(BOR)
	$(BOR) emit-c test/melodica -o $(BOR_C)

$(BOR_C): $(BOR) test/melodica/main.odin
	$(BOR) emit-c test/melodica -o $(BOR_C)

$(BUILD)/smoke-gcc: $(BOR_C) test/c99/smoke.c
	$(CC) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(BOR_C) test/c99/smoke.c -o $@

$(BUILD)/smoke-clang: $(BOR_C) test/c99/smoke.c
	$(CLANG) -std=c99 -pedantic-errors -Wall -Wextra -Werror -O3 $(BOR_C) test/c99/smoke.c -o $@

$(BUILD)/native-melodica.a: test/melodica/main.odin | $(BUILD)
	$(ODIN) build test/melodica -build-mode:static -out:$@ -o:speed -reloc-mode:pic -no-entry-point

$(BUILD)/smoke-native: $(BUILD)/native-melodica.a test/c99/smoke.c
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 test/c99/smoke.c $(BUILD)/native-melodica.a -lm -ldl -lpthread -o $@

test: $(BUILD)/smoke-gcc $(BUILD)/smoke-clang $(BUILD)/smoke-native
	./$(BUILD)/smoke-gcc
	./$(BUILD)/smoke-clang
	./$(BUILD)/smoke-native
	@echo 'Bor: strict C99 GCC + Clang + native Odin behavior agree'

clean:
	rm -rf $(BUILD)
