# Whisper Russian Code-Switch

This branch adds a local FluidVoice speech engine for [coriollon's Whisper Russian Code-Switch](https://huggingface.co/coriollon/whisper-large-v3-turbo-russian-codeswitch), licensed Apache 2.0. It targets Russian dictation with English IT terms. The model card's accuracy figures come from synthetic speech; test it on your own recordings before relying on it.

## Get and convert the model

FluidVoice needs a **transcribe.cpp GGUF**. The source `model.safetensors` cannot be selected directly. The source is pinned to Hugging Face revision `bf64d2a976a268e35041f74233f889f951f0f676`; `model.safetensors` must be **3,235,581,408 bytes** and have SHA-256 `4b1891beb4efbdf22605046229acbc060d873c8fc32f3ec6e2e1c0ac64651056`.

The pinned [CI conversion artifact](https://github.com/terichev/FluidVoice/actions/runs/39050575686/artifacts/12108030497) contains a ready Q8_0 GGUF. Its verified size is **886,381,856 bytes** and SHA-256 is `a12631be9408e83ca5145bdf577cc2243ed8960a907f74e1866f9078abbb2541`. It was loaded successfully by FluidVoice's bundled CTranscribe runtime and by the installed app on Metal. GitHub Actions artifacts expire, so use the reproducible conversion steps below if the link is no longer available.

To convert the Safetensors source yourself, transfer `model.safetensors` to this Mac first. Install Python 3.10 or newer, CMake, and a C++ compiler, then run from a working directory with at least 10 GB free. The command below downloads only small configuration and tokenizer files, **not** the 3.24 GB weights again:

```bash
python3 -m venv .venv-codeswitch
source .venv-codeswitch/bin/activate
python -m pip install 'torch>=2.4' 'gguf>=0.10' 'huggingface-hub>=0.30' 'librosa>=0.10' 'safetensors>=0.4' 'soundfile>=0.12' 'numpy>=1.26' 'transformers==5.6.1'
mkdir -p codeswitch-source
cp /path/to/transferred/model.safetensors codeswitch-source/model.safetensors
python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="coriollon/whisper-large-v3-turbo-russian-codeswitch",
    revision="bf64d2a976a268e35041f74233f889f951f0f676",
    local_dir="codeswitch-source",
    allow_patterns=[
        "config.json", "generation_config.json",
        "preprocessor_config.json", "tokenizer.json",
    ],
)
PY
test "$(stat -f '%z' codeswitch-source/model.safetensors)" = 3235581408
echo '4b1891beb4efbdf22605046229acbc060d873c8fc32f3ec6e2e1c0ac64651056  codeswitch-source/model.safetensors' | shasum -a 256 -c -

git clone https://github.com/handy-computer/transcribe.cpp.git
git -C transcribe.cpp checkout 33d5c383e43e6acbd572845866ea75b8c7959fa5 # v0.1.2
python transcribe.cpp/scripts/convert-whisper.py codeswitch-source codeswitch-F32.gguf \
  --repo-id coriollon/whisper-large-v3-turbo-russian-codeswitch \
  --variant whisper-large-v3-turbo
cmake -S transcribe.cpp -B transcribe.cpp/build -DCMAKE_BUILD_TYPE=Release
cmake --build transcribe.cpp/build --target transcribe-quantize -j 8
transcribe.cpp/build/bin/transcribe-quantize codeswitch-F32.gguf codeswitch-Q8_0.gguf --quant Q8_0
```

The converter comes from pinned transcribe.cpp commit `33d5c383e43e6acbd572845866ea75b8c7959fa5`, including `scripts/lib`. Its required source files are `config.json`, `generation_config.json`, `preprocessor_config.json`, `tokenizer.json`, and `model.safetensors` in one directory. It writes an F32 GGUF first; the last command makes the smaller Q8_0 GGUF. The [model conversion workflow](https://github.com/terichev/FluidVoice/actions/runs/39050575686) completed this conversion for the pinned source. Verify the checksum and confirm that a locally converted Q8_0 file loads in transcribe.cpp before installing it. If either command fails, do not relabel the Safetensors file as GGUF.

## Install in FluidVoice

From this FluidVoice branch, calculate the output file's SHA-256 and pass it to the installer:

```bash
shasum -a 256 codeswitch-Q8_0.gguf
scripts/install_russian_codeswitch_model.sh "$PWD/codeswitch-Q8_0.gguf" OUTPUT_SHA256_FROM_THE_PREVIOUS_COMMAND
```

The installer checks file size and GGUF header, compares SHA-256 before and after copying, and atomically writes `~/Library/Caches/WhisperModels/whisper-russian-codeswitch.gguf`. It never downloads a model. Open **Voice Engine**, refresh the list, and activate **Whisper Russian Code-Switch**. Russian is the default language if no Whisper language was selected; you can change it manually. With filler removal enabled, this branch removes only standalone `э`, `ээ`, `эээ`, `эм`, `ммм`, and `э-э-э` variants for this model. It preserves `ну` and `вот`.

## App build and updates

The official FluidVoice 1.6.11 app does not contain this model. The **Russian Code-Switch Release** GitHub Actions workflow builds a Release `FluidVoice.app` artifact from this branch after a push or manual start. Its signature is ad hoc, unlike the official Developer ID signed and notarized app. Installing it over `/Applications/FluidVoice.app` may require granting Microphone, Accessibility, and Screen Recording permissions again. A later official update can replace the custom build; keep a backup until it is tested.
