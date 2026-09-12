#!/bin/sh
# Downloads to an explicit project/CI directory; never mutates the host installation.
set -eu
DEST=${1:?usage: setup-toolchains.sh DESTINATION}
case "$(uname -s)/$(uname -m)" in Linux/x86_64) ;; *) echo 'Pinned bootstrap supports Linux/amd64; use an installed Odin and Zig elsewhere.' >&2; exit 2;; esac
mkdir -p "$DEST/odin" "$DEST/zig"
curl -fSL --retry 3 https://github.com/odin-lang/Odin/releases/download/dev-2026-09/odin-linux-amd64-dev-2026-09.tar.gz -o "$DEST/odin.tar.gz"
echo "167c3e1d7056419dad2e04bb3bd98715b7ff286d4c125f3c5a5ee337c6254283  $DEST/odin.tar.gz" | sha256sum -c -
tar -xzf "$DEST/odin.tar.gz" -C "$DEST/odin" --strip-components=1
curl -fSL --retry 3 https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz -o "$DEST/zig.tar.xz"
echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  $DEST/zig.tar.xz" | sha256sum -c -
tar -xJf "$DEST/zig.tar.xz" -C "$DEST/zig" --strip-components=1
"$DEST/odin/odin" version
"$DEST/zig/zig" version
