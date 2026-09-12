package main

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

VERSION :: "0.1.0-dev"
HELP :: `Borr - Odin to portable C99

  bor emit-c PATH [-o FILE.c] [--no-opt]
  bor check PATH [--no-opt]
  bor ir    PATH [--no-opt]
  bor eval  PATH [--entry NAME] [--arg INTEGER]... [--steps N] [--no-opt]

PATH is one .odin file or one package directory. The compiler's supported
language profile is checked independently; unsupported syntax is an error.
The bounded IR interpreter is a testing tool, not a production VM.
`

read_sources :: proc(path: string) -> (files: []^ast.File, ok: bool) {
    paths: []string
    if strings.has_suffix(path, ".odin") { paths = []string{path} }
    else {
        matches, err := filepath.glob(fmt.tprintf("%s/*.odin", path))
        if err != nil || len(matches) == 0 { fmt.eprintf("%s: B0001: no Odin source files\n", path); return }
        paths = matches
    }
    slice.sort(paths)
    list: [dynamic]^ast.File
    package_name: string
    for name in paths {
        _, base := os.split_path(name)
        suffixes := []string{"_test.odin", "_windows.odin", "_linux.odin", "_darwin.odin", "_freebsd.odin", "_openbsd.odin", "_netbsd.odin", "_wasi.odin", "_js.odin", "_orca.odin", "_freestanding.odin", "_unix.odin", "_amd64.odin", "_i386.odin", "_arm32.odin", "_arm64.odin", "_wasm32.odin", "_wasm64p32.odin", "_riscv64.odin"}
        for suffix in suffixes {
            if strings.has_suffix(base,suffix) {
                fmt.eprintf("%s: B0016: target/test file selection is not supported by the explicit scalar profile\n",name)
                return
            }
        }
        data, err := os.read_entire_file(name, context.allocator)
        if err != nil { fmt.eprintf("%s: B0002: cannot read source: %v\n", name, err); return }
        file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
        file.fullpath = name
        file.src = string(data)
        p := parser.default_parser()
        if !parser.parse_file(&p, file) || file.syntax_error_count > 0 { return }
        if file.pkg_decl == nil { fmt.eprintf("%s: B0003: missing package declaration\n", name); return }
        if package_name != "" && package_name != file.pkg_name { fmt.eprintf("%s: B0004: inconsistent package names\n", name); return }
        package_name = file.pkg_name
        append(&list, file)
    }
    return list[:], true
}

run :: proc() -> int {
    if len(os.args) == 2 && os.args[1] == "--version" { fmt.printf("Borr %s\n", VERSION); return 0 }
    if len(os.args) < 3 {
        fmt.print(HELP)
        return 0 if len(os.args) == 2 && os.args[1] == "--help" else 2
    }
    arena: virtual.Arena
    if err := virtual.arena_init_growing(&arena); err != nil { fmt.eprintln("B0005: cannot allocate compilation arena"); return 2 }
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    context.temp_allocator = context.allocator
    command, path := os.args[1], os.args[2]
    if command == "emit-c" { command = "emit" }
    if command != "check" && command != "emit" && command != "eval" && command != "ir" { fmt.eprintf("B0006: unknown command '%s'\n", command); return 2 }
    optimize_enabled := true
    output, entry := "", "main"
    args: [dynamic]u64
    steps: u64 = 10_000_000
    i := 3
    for i < len(os.args) {
        option := os.args[i]
        if option == "--no-opt" { optimize_enabled = false; i += 1; continue }
        if i+1 >= len(os.args) { fmt.eprintf("B0007: missing value for %s\n", option); return 2 }
        argument := os.args[i+1]
        switch option {
        case "-o": output = argument
        case "--entry": entry = argument
        case "--steps":
            n, ok := parse_integer(argument)
            if !ok || n == 0 { fmt.eprintln("B0008: invalid instruction budget"); return 2 }
            steps = n
        case "--arg":
            text := argument
            negative := strings.has_prefix(text, "-")
            if negative { text = text[1:] }
            n, ok := parse_integer(text)
            if !ok { fmt.eprintln("B0009: invalid integer argument"); return 2 }
            if negative { n = u64(0)-n }
            append(&args, n)
        case: fmt.eprintf("B0010: unknown option %s\n", option); return 2
        }
        i += 2
    }
    files, ok := read_sources(path)
    if !ok { return 1 }
    program := collect_and_check(files)
    if len(program.diagnostics) == 0 {
        for &p in program.procs {
            if !verify(&program, &p) { break }
            if optimize_enabled { optimize(&p) }
            if !verify(&program, &p) { break }
        }
    }
    if len(program.diagnostics) != 0 {
        for d in program.diagnostics { fmt.eprintf("%s(%d:%d): %s: %s\n", d.pos.file, d.pos.line, d.pos.column, d.code, d.message) }
        return 1
    }
    switch command {
    case "emit":
        text := emit_c99(&program)
        if output == "" { fmt.print(text) }
        else {
            // Never overwrite any source file with generated output.
            absolute, _ := os.get_absolute_path(output, context.allocator)
            destination, destination_error := os.stat(output, context.allocator)
            for file in files {
                input, _ := os.get_absolute_path(file.fullpath, context.allocator)
                source, source_error := os.stat(file.fullpath, context.allocator)
                alias := destination_error == nil && source_error == nil && (os.same_file(source,destination) || (source.inode != 0 && source.inode == destination.inode && source.device == destination.device))
                if input == absolute || alias { fmt.eprintln("B0011: output would overwrite input"); return 2 }
            }
            if err := os.write_entire_file(output, text); err != nil { fmt.eprintf("B0012: cannot write %s: %v\n", output, err); return 2 }
        }
    case "ir":
        for &p in program.procs {
            fmt.printf("proc %s -> %v (%d slots)\n", p.name, p.result, len(p.slots))
            for inst, j in p.code { fmt.printf("  %d: %v %v a=%d b=%d slot=%d target=%d/%d bits=%d callee=%d args=%d+%d\n", j, inst.op, inst.type, inst.a, inst.b, inst.slot, inst.target, inst.otherwise, inst.bits, inst.callee, inst.args.start, inst.args.count) }
        }
    case "eval":
        id, found := program.names[entry]
        if !found { fmt.eprintf("B0013: no procedure '%s'\n", entry); return 2 }
        p := &program.procs[id]
        if len(args) != p.parameter_count { fmt.eprintln("B0014: argument count mismatch"); return 2 }
        for value, j in args { if p.slots[j].type == .Bool && value > 1 { fmt.eprintln("B0015: boolean argument must be 0 or 1"); return 2 } }
        vm := VM{program=&program, remaining=steps}
        value, err := interpret(&vm, id, args[:])
        if err != .None { fmt.eprintf("%s(%d:%d): B2000: %v\n", vm.fault.file, vm.fault.line, vm.fault.column, err); return 1 }
        if is_signed(p.result) { fmt.println(transmute(i64)value) }
        else if p.result != .Void { fmt.println(value) }
    }
    return 0
}

main :: proc() { os.exit(run()) }
