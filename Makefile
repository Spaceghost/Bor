ODIN ?= odin
CC ?= cc
CLANG ?= clang
BUILD := build
BOR := $(BUILD)/bor
DIRECT_C := $(BUILD)/direct-melodica.c
MIR_C := $(BUILD)/mir-melodica.c
LINKAGE_DIRECT_C := $(BUILD)/direct-linkage.c
LINKAGE_MIR_C := $(BUILD)/mir-linkage.c

.PHONY: all bor emit test clean

all: test

$(BUILD):
	mkdir -p $(BUILD)

bor: $(BOR)

$(BOR): src/*.odin | $(BUILD)
	$(ODIN) build src -out:$(BOR) -o:speed

emit: $(DIRECT_C) $(MIR_C) $(LINKAGE_DIRECT_C) $(LINKAGE_MIR_C)

$(DIRECT_C): $(BOR) test/melodica/main.odin
	$(BOR) emit-c-direct test/melodica -o $@

$(MIR_C): $(BOR) test/melodica/main.odin
	$(BOR) emit-c-mir test/melodica -o $@

$(LINKAGE_DIRECT_C): $(BOR) test/linkage/main.odin
	$(BOR) emit-c-direct test/linkage -o $@

$(LINKAGE_MIR_C): $(BOR) test/linkage/main.odin
	$(BOR) emit-c-mir test/linkage -o $@

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

$(BUILD)/native-melodica.a: test/melodica/main.odin | $(BUILD)
	$(ODIN) build test/melodica -build-mode:static -out:$@ -o:speed -reloc-mode:pic -no-entry-point

$(BUILD)/smoke-native: $(BUILD)/native-melodica.a test/c99/smoke.c
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 test/c99/smoke.c $(BUILD)/native-melodica.a -lm -ldl -lpthread -o $@

$(BUILD)/native-linkage.a: test/linkage/main.odin | $(BUILD)
	$(ODIN) build test/linkage -build-mode:static -out:$@ -o:speed -reloc-mode:pic -no-entry-point

$(BUILD)/linkage-native: $(BUILD)/native-linkage.a test/c99/linkage_smoke.c
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 test/c99/linkage_smoke.c $(BUILD)/native-linkage.a -lm -ldl -lpthread -o $@

test: $(BUILD)/smoke-direct-gcc $(BUILD)/smoke-direct-clang $(BUILD)/smoke-mir-gcc $(BUILD)/smoke-mir-clang $(BUILD)/smoke-native $(BUILD)/linkage-direct-gcc $(BUILD)/linkage-direct-clang $(BUILD)/linkage-mir-gcc $(BUILD)/linkage-mir-clang $(BUILD)/linkage-native
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
	@echo 'Bor: direct C99, flat MIR C99, and native Odin behavior agree'
	@echo 'Bor: calling convention and export linkage remain independent'

clean:
	rm -rf $(BUILD)
