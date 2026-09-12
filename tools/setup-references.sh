#!/bin/sh
set -eu
DEST=${1:?usage: setup-references.sh DESTINATION}
mkdir -p "$DEST"
fetch() {
    repo=$1 name=$2 revision=$3
    if [ ! -d "$DEST/$name/.git" ]; then git clone "$repo" "$DEST/$name"; fi
    test -z "$(git -C "$DEST/$name" status --porcelain --untracked-files=no)" || { echo "Refusing to overwrite tracked changes in $name" >&2; exit 1; }
    git -C "$DEST/$name" fetch origin "$revision"
    git -C "$DEST/$name" checkout --detach "$revision"
    test "$(git -C "$DEST/$name" rev-parse HEAD)" = "$revision"
}
fetch https://github.com/Spaceghost/codin.git codin 5cd28a63023c24079f16e9a51a0140501cebdfa2
fetch https://github.com/Spaceghost/Thor.git Thor c9665a453aeaab31ec728d2d9c3172f41b52b87b
sh "$DEST/codin/scripts/build-experimental-c99.sh" > "$DEST/codin-build.log" 2>&1 || { cat "$DEST/codin-build.log" >&2; exit 1; }
make -C "$DEST/Thor" -j2 CC=clang > "$DEST/thor-build.log" 2>&1 || { cat "$DEST/thor-build.log" >&2; exit 1; }
printf '%s\n' 'Pinned references built; Thor is a parser/AST-dump control, not a C compiler lane.'
