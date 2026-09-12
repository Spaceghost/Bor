#!/usr/bin/env python3
"""Generate deterministic Odin/C differential workloads for Bor.

The generator stays inside Bor's currently admitted u32 subset, but composes the
operators aggressively enough to expose precedence, spelling, cast, CFG, and
compound-assignment mistakes.  Native Odin is the semantic oracle; the same C
harness is linked against Bor direct, Bor MIR, and native Odin builds.
"""

from __future__ import annotations

import argparse
import random
from pathlib import Path


def statement_pool(rng: random.Random) -> list[str]:
    vars_ = ["x", "y", "z"]
    a = rng.choice(vars_)
    b = rng.choice(vars_)
    c = rng.choice(vars_)
    shift = f"({b} & {rng.choice([3, 7, 15, 31])})"
    odd = f"({b} | 1)"
    mask = rng.choice(["0xff", "0xffff", "0x55555555", "0xaaaaaaaa", "0x9e3779b9"])

    choices = [
        f"{a} += {b}",
        f"{a} -= {b}",
        f"{a} *= ({b} | 1)",
        f"{a} /= {odd}",
        f"{a} %= {odd}",
        f"{a} &= ({b} | {mask})",
        f"{a} |= ({b} & {mask})",
        f"{a} ~= ({b} + {c})",
        f"{a} <<= {shift}",
        f"{a} >>= {shift}",
        f"{a} = {a} &~ {b}",
        f"{a} = ~{a}",
        f"{a} = ({a} << {shift}) | ({a} >> ((32 - {shift}) & 31))",
        f"{a} = {a} ~ u32(u8({b}))",
        f"{a} = ({a} + {b}) ~ ({c} * 33)",
    ]
    return choices


def generate_odin(variant: int) -> str:
    rng = random.Random(0xB0B0_0000 + variant)
    prelude: list[str] = []
    loop_body: list[str] = []

    for _ in range(18):
        prelude.append(rng.choice(statement_pool(rng)))

    for _ in range(12):
        loop_body.append(rng.choice(statement_pool(rng)))

    cmp_a = rng.choice(["<", ">", "<=", ">=", "!=", "=="])
    cmp_b = rng.choice(["<", ">", "<=", ">=", "!=", "=="])
    logical = rng.choice(["&&", "||"])

    lines = [
        "package fuzz",
        "",
        "@(export)",
        'fuzz_checksum :: proc "c" (seed: u32) -> u32 {',
        "\tx := seed ~ 0x9e3779b9",
        "\ty := seed + 0x7f4a7c15",
        "\tz := (seed * 1664525) + 1013904223",
    ]
    lines += [f"\t{s}" for s in prelude]
    lines += [
        f"\tif (x {cmp_a} y) {logical} (z {cmp_b} x) {{",
        "\t\tx = (x + z) ~ (y >> 3)",
        "\t\ty = y &~ (z >> 7)",
        "\t} else {",
        "\t\tx = (x | z) - y",
        "\t\ty = y ~ (x << 5)",
        "\t}",
        "",
        "\tfor i in 0..<8 {",
        "\t\tk := u32(i)",
        "\t\tz += (k * 0x45d9f3b) | 1",
    ]
    lines += [f"\t\t{s}" for s in loop_body]
    lines += [
        "\t\tif (x & 3) == 0 {",
        "\t\t\ty += x | k",
        "\t\t} else {",
        "\t\t\ty = y &~ (x ~ k)",
        "\t\t}",
        "\t}",
        "",
        "\treturn (x ~ y) + (z * 0x27d4eb2d)",
        "}",
        "",
    ]
    return "\n".join(lines)


def generate_harness() -> str:
    seeds = [
        0,
        1,
        2,
        3,
        7,
        31,
        0x12345678,
        0x80000000,
        0xDEADBEEF,
        0xFFFFFFFF,
        0xA5A5A5A5,
        0x5A5A5A5A,
    ]
    seed_text = ", ".join(f"UINT32_C(0x{s:08x})" for s in seeds)
    return f'''#include <inttypes.h>\n#include <stdint.h>\n#include <stdio.h>\n\nextern uint32_t fuzz_checksum(uint32_t seed);\n\nint main(void) {{\n    static const uint32_t seeds[] = {{{seed_text}}};\n    for (size_t i = 0; i < sizeof(seeds) / sizeof(seeds[0]); ++i) {{\n        printf("%08" PRIx32 "\\n", fuzz_checksum(seeds[i]));\n    }}\n    return 0;\n}}\n'''


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", type=int, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    root = args.out
    odin_dir = root / "odin"
    odin_dir.mkdir(parents=True, exist_ok=True)
    (odin_dir / "main.odin").write_text(generate_odin(args.variant), encoding="utf-8")
    (root / "harness.c").write_text(generate_harness(), encoding="utf-8")


if __name__ == "__main__":
    main()
