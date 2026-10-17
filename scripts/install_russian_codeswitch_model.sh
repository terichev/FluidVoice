#!/usr/bin/env bash

# Installs an independently verified transcribe.cpp GGUF for the local
# Whisper Russian Code-Switch option. Never downloads or converts a model.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/install_russian_codeswitch_model.sh <converted-model.gguf> <expected-sha256>

The second argument must be the trusted SHA-256 of the converted GGUF file.
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage
source_path=$1
expected_sha=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
[[ -f "$source_path" ]] || { echo "Model file is missing: $source_path" >&2; exit 1; }
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "Expected SHA-256 must be 64 hexadecimal characters." >&2; exit 2; }

model_bytes=$(stat -f '%z' "$source_path")
[[ "$model_bytes" -gt 100000000 ]] || { echo "GGUF is unexpectedly small ($model_bytes bytes)." >&2; exit 1; }
magic=$(head -c 4 "$source_path" | od -An -tx1 | tr -d '[:space:]')
[[ "$magic" == "47475546" ]] || { echo "File is not GGUF (missing GGUF header)." >&2; exit 1; }

actual_sha=$(shasum -a 256 "$source_path" | awk '{print $1}')
[[ "$actual_sha" == "$expected_sha" ]] || { echo "SHA-256 mismatch for $source_path." >&2; exit 1; }

model_dir="$HOME/Library/Caches/WhisperModels"
model_path="$model_dir/whisper-russian-codeswitch.gguf"
mkdir -p "$model_dir"
temporary_path=$(mktemp "$model_dir/.russian-codeswitch.XXXXXXXX")
trap 'rm -f "$temporary_path"' EXIT
cp "$source_path" "$temporary_path"
copied_sha=$(shasum -a 256 "$temporary_path" | awk '{print $1}')
[[ "$copied_sha" == "$expected_sha" ]] || { echo "Copied GGUF failed SHA-256 verification." >&2; exit 1; }
chmod 0644 "$temporary_path"
mv -f "$temporary_path" "$model_path"
trap - EXIT

echo "Installed verified GGUF at: $model_path"
echo "Open FluidVoice → Voice Engine → Whisper Russian Code-Switch, refresh the model list, and activate it."
