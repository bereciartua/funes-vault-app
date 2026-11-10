#!/bin/sh
# Checks the bundled embedding model (ADR-0016) against the checksums pinned in
# scripts/fetch_embedding_model.sh, file by file.
#
# Usage: sh scripts/check_embedding_model.sh SOURCE [COMPILED]
#   SOURCE    A folder with bge-small-en-v1.5.mlpackage and vocab.txt (the model cache, or the
#             release workflow's model artifact). The package must hold exactly the files in
#             PACKAGE_FILES, each with its pinned SHA-256, and vocab.txt must be the pinned one.
#   COMPILED  A folder with bge-small-en-v1.5.mlmodelc and vocab.txt (the cache, or the app's
#             Resources/bge-small-en-v1.5). Its compiled model must be exactly what this Mac's
#             coremlcompiler makes of the checked package: the same files, byte for byte, nothing
#             more. A compiled model isn't pinned by checksum itself, since coremlcompiler writes
#             its own and the OS's versions into it.
# Used by fetch_embedding_model.sh, embed_resources.sh, check_bundle.sh and the release workflow.
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fetch="$project_dir/scripts/fetch_embedding_model.sh"
name=bge-small-en-v1.5
source_dir=${1:?usage: check_embedding_model.sh SOURCE [COMPILED]}
compiled_dir=${2:-}

fail() { printf 'check_embedding_model: %s\n' "$*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
# Only regular files and folders: a link could point anywhere.
plain() { [ -z "$(find "$1" ! -type f ! -type d)" ]; }

pins=$(sed -n '/^PACKAGE_FILES="$/,/^"$/p' "$fetch" | sed '1d;$d')
vocab_sha=$(sed -n 's/^vocab.txt \([0-9a-f]*\)$/\1/p' "$fetch")
[ -n "$pins" ] && [ -n "$vocab_sha" ] \
    || fail "can't read the pinned checksums from scripts/fetch_embedding_model.sh"

package="$source_dir/$name.mlpackage"
[ -d "$package" ] || fail "$package is missing"
plain "$package" || fail "$package holds something other than files and folders"
expected=$(printf '%s\n' "$pins" | awk 'NF { print $1 }' | LC_ALL=C sort)
actual=$(cd "$package" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
[ "$actual" = "$expected" ] || fail "$package doesn't hold exactly the pinned files"
while read -r file checksum; do
    [ -n "$file" ] || continue
    [ "$(sha "$package/$file")" = "$checksum" ] || fail "$package/$file isn't the pinned file"
done <<EOF
$pins
EOF
[ -f "$source_dir/vocab.txt" ] && [ "$(sha "$source_dir/vocab.txt")" = "$vocab_sha" ] \
    || fail "$source_dir/vocab.txt isn't the pinned vocabulary"

[ -n "$compiled_dir" ] || exit 0
model="$compiled_dir/$name.mlmodelc"
[ -d "$model" ] || fail "$model is missing"
plain "$model" || fail "$model holds something other than files and folders"
[ -f "$compiled_dir/vocab.txt" ] && [ "$(sha "$compiled_dir/vocab.txt")" = "$vocab_sha" ] \
    || fail "$compiled_dir/vocab.txt isn't the pinned vocabulary"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/check_embedding_model.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun coremlcompiler compile "$package" "$scratch" > /dev/null \
    || fail "coremlcompiler couldn't compile $package"
diff -r "$scratch/$name.mlmodelc" "$model" > /dev/null \
    || fail "$model isn't what coremlcompiler makes of the pinned package"
