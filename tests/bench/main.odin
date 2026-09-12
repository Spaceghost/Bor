package benchmark

// Shared source for Borr, Codin, and native Odin. No backend-specific rewrites.
@(export)
mix32 :: proc "c" (seed: u32, count: uintptr) -> u32 {
    state := seed
    for i in 0..<count {
        state = state*1664525 + 1013904223
    }
    return state
}
