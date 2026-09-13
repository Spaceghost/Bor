// Algorithm-matched to lut.c. ReleaseFast and ReleaseSafe are separate entrants.
// Optional many-pointers retain the original C ABI's null-pointer behavior.
const width: [256]u8 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u8 = undefined;
    for (0..256) |c| {
        const keep = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
        table[c] = if (keep) 1 else 3;
    }
    break :blk table;
};
const hex = "0123456789ABCDEF";
export fn melodica_abi_version() u32 { return 1; }
export fn melodica_url_encode_size(src: ?[*]const u8, len: usize) usize {
    const input = src orelse return 0;
    var required: usize = 0;
    for (input[0..len]) |c| required +%= width[c];
    return required;
}
export fn melodica_url_encode(dst: ?[*]u8, cap: usize, src: ?[*]const u8, len: usize) usize {
    const required = melodica_url_encode_size(src, len);
    const input = src orelse return required;
    const output = dst orelse return required;
    if (cap < required) return required;
    var out: usize = 0;
    for (input[0..len]) |c| {
        if (width[c] == 1) {
            output[out] = c;
            out += 1;
        } else {
            output[out] = '%';
            output[out + 1] = hex[c >> 4];
            output[out + 2] = hex[c & 15];
            out += 3;
        }
    }
    return required;
}
