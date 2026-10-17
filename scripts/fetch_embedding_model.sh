#!/bin/sh
# Fetches the bundled embedding model (ADR-0016): BAAI/bge-small-en-v1.5 at a pinned Hugging Face
# revision, verifies every file's SHA-256, converts it to Core ML (an ML Program computed in fp16
# with int8 weights, CLS pooling and L2 normalization inside, lengths 16–256), checks it against
# reference vectors, verifies the output checksum and compiles it. Nothing is committed to git: the result is cached in
#   ${FUNES_MODEL_CACHE:-~/Library/Caches/com.funesvault.dev}/bge-small-en-v1.5-<revision>/
# as bge-small-en-v1.5.mlpackage, bge-small-en-v1.5.mlmodelc, vocab.txt and manifest.json.
# FunesCore's model-dependent tests look there (or in FUNES_EMBEDDING_MODEL_DIR).
#
# Needs curl, Python 3.11 (FUNES_PYTHON, default python3.11) and Xcode's coremlcompiler.
# Set FUNES_MODEL_FP16=1 to also write the fp16-weight variant (bge-small-en-v1.5-fp16.*), the
# Spike 2b model: same recall on the benchmark at twice the size (phase-1 notes in spike-results.md).
set -eu
cd "$(dirname "$0")/.."

REPO="BAAI/bge-small-en-v1.5"
REVISION="5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
NAME="bge-small-en-v1.5"
# SHA-256 of the Hugging Face files at REVISION.
FILES="
config.json 094f8e891b932f2000c92cfc663bac4c62069f5d8af5b5278c4306aef3084750
vocab.txt 07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3
tokenizer.json d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66
model.safetensors 3c9f31665447c8911517620762200d2245a2518d6e7208acc78cd9db317e21ad
"
# SHA-256 of the converted weights (the .mlpackage's weight.bin; the package manifest holds
# random ids, so the package as a whole isn't byte-stable). Changes only with the pinned tools.
WEIGHTS_SHA256="c63414a4246ebec815ffdc2a55750fbb8ca2ea31186b21db4020a77742d047e1"
FP16_WEIGHTS_SHA256="549e19d82b7cc5154ea30e517c775b0490dc709aed7a704b6aa79349c800f1a6"

CACHE="${FUNES_MODEL_CACHE:-$HOME/Library/Caches/com.funesvault.dev}"
DIR="$CACHE/$NAME-$(echo "$REVISION" | cut -c1-7)"
PYTHON="${FUNES_PYTHON:-python3.11}"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
weights() { find "$1" -name weight.bin | head -n 1; }

if [ -f "$DIR/manifest.json" ] && [ -d "$DIR/$NAME.mlmodelc" ] && [ -f "$DIR/vocab.txt" ] \
    && [ "$(sha "$(weights "$DIR/$NAME.mlpackage")")" = "$WEIGHTS_SHA256" ]; then
    echo "fetch_embedding_model: cached at $DIR"
    exit 0
fi

mkdir -p "$DIR/hf"
echo "$FILES" | while read -r file expected; do
    [ -n "$file" ] || continue
    dest="$DIR/hf/$file"
    if [ ! -f "$dest" ] || [ "$(sha "$dest")" != "$expected" ]; then
        echo "fetch_embedding_model: downloading $file"
        curl -fsSL --retry 3 -o "$dest.part" "https://huggingface.co/$REPO/resolve/$REVISION/$file"
        mv "$dest.part" "$dest"
    fi
    actual=$(sha "$dest")
    if [ "$actual" != "$expected" ]; then
        echo "error: $file has SHA-256 $actual, expected $expected" >&2
        rm -f "$dest"
        exit 1
    fi
done

VENV="$DIR/venv"
if [ ! -x "$VENV/bin/python" ]; then
    "$PYTHON" -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --quiet --disable-pip-version-check -r scripts/embedding_model/requirements.txt

convert() {  # convert <output name> <expected weights SHA-256> [int8]
    rm -rf "$DIR/$1.mlpackage" "$DIR/$1.mlmodelc"
    "$VENV/bin/python" -I scripts/embedding_model/convert.py "$DIR/hf" "$DIR/$1.mlpackage" \
        scripts/embedding_model/reference.json ${3:-}
    actual=$(sha "$(weights "$DIR/$1.mlpackage")")
    if [ "$actual" != "$2" ]; then
        echo "error: converted weights of $1 have SHA-256 $actual, expected $2" >&2
        exit 1
    fi
    xcrun coremlcompiler compile "$DIR/$1.mlpackage" "$DIR" >/dev/null
}
convert "$NAME" "$WEIGHTS_SHA256" int8
if [ "${FUNES_MODEL_FP16:-0}" = "1" ]; then
    convert "$NAME-fp16" "$FP16_WEIGHTS_SHA256"
fi
cp "$DIR/hf/vocab.txt" "$DIR/vocab.txt"
cat > "$DIR/manifest.json" <<JSON
{"model": "$REPO", "revision": "$REVISION", "modelId": "$NAME/coreml-int8", "weightsSHA256": "$WEIGHTS_SHA256"}
JSON
echo "fetch_embedding_model: ready at $DIR"
