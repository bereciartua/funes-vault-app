#!/bin/sh
# Xcode build phase of the FunesMac target ("Embed Resources"): copies the license files
# (LICENSE, NOTICE and Licenses/*.txt, the third-party licenses NOTICE points to) into
# FunesVault.app/Contents/Resources/, and the bundled model (ADR-0016) into
# Contents/Resources/bge-small-en-v1.5/ as
# bge-small-en-v1.5.mlmodelc and vocab.txt, from the copy scripts/fetch_embedding_model.sh makes
# (FUNES_EMBEDDING_MODEL_DIR, else ~/Library/Caches/com.funesvault.dev/bge-small-en-v1.5-<rev>/).
# The compiled weights and the vocabulary must match the checksums pinned in
# fetch_embedding_model.sh, so a build never ships another model.
#
# Release builds fail without the model: a release must never fall back to keyword search
# silently. Debug builds skip it with a warning, and the app then looks in the cache folder itself.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fetch="$project_dir/scripts/fetch_embedding_model.sh"
name=bge-small-en-v1.5
revision=$(sed -n 's/^REVISION="\([0-9a-f]*\)"$/\1/p' "$fetch")
weights_sha=$(sed -n 's/^WEIGHTS_SHA256="\([0-9a-f]*\)"$/\1/p' "$fetch")
vocab_sha=$(sed -n 's/^vocab.txt \([0-9a-f]*\)$/\1/p' "$fetch")
[ -n "$revision" ] && [ -n "$weights_sha" ] && [ -n "$vocab_sha" ] || {
    echo "error: can't read the pinned model checksums from scripts/fetch_embedding_model.sh" >&2
    exit 1
}
source_dir=${FUNES_EMBEDDING_MODEL_DIR:-$HOME/Library/Caches/com.funesvault.dev/$name-$(echo "$revision" | cut -c1-7)}
resources="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
destination="$resources/$name"

mkdir -p "$resources/Licenses"
cp "$project_dir/LICENSE" "$project_dir/NOTICE" "$resources/"
rsync -a --delete "$project_dir/Licenses/" "$resources/Licenses/"

missing() {
    if [ "${CONFIGURATION:-}" = Release ]; then
        echo "error: $1. Run: sh scripts/fetch_embedding_model.sh" >&2
        exit 1
    fi
    echo "warning: $1; this Debug build uses the model in the cache folder, or keyword search" >&2
    rm -rf "$destination"
    exit 0
}

[ -d "$source_dir/$name.mlmodelc" ] && [ -f "$source_dir/vocab.txt" ] \
    || missing "the embedding model isn't at $source_dir"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
[ "$(sha "$source_dir/$name.mlmodelc/weights/weight.bin")" = "$weights_sha" ] \
    || missing "$source_dir/$name.mlmodelc has weights other than the pinned ones"
[ "$(sha "$source_dir/vocab.txt")" = "$vocab_sha" ] \
    || missing "$source_dir/vocab.txt isn't the pinned vocabulary"

mkdir -p "$destination"
rsync -a --delete "$source_dir/$name.mlmodelc" "$destination/"
cp "$source_dir/vocab.txt" "$destination/vocab.txt"
echo "embed_embedding_model: $name ($weights_sha) in $destination"
