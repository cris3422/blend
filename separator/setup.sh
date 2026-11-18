#!/bin/zsh
# One-time install of Blend's AI tools: song analysis (beats, key, sections) and stem splitting.
# About 1 GB, all inside ~/Library/Application Support/Blend/separator (delete that folder to remove it):
#   - Python 3.11 via uv (https://docs.astral.sh/uv/)
#   - PyTorch with Apple GPU support (BSD-style licence)
#   - Demucs 4.0.1 (Meta, MIT) for vocals / drums / bass / other; model weights fetched on first run
#   - beat_this 1.1.0 (CPJKU, MIT) for beats and downbeats
#   - Music-Source-Separation-Training (ZFTurbo, MIT) model code + BandIt Plus weights for the effects stem (optional)
# usage: zsh separator/setup.sh
set -e
HERE="${0:A:h}"
DEST="$HOME/Library/Application Support/Blend/separator"
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
[[ -x "$UV" ]] || { echo "uv not found. Install it first: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
mkdir -p "$DEST"; cd "$DEST"
"$UV" python install 3.11
[[ -x venv/bin/python ]] || "$UV" venv --python 3.11 venv
"$UV" pip install --python venv/bin/python torch torchaudio "demucs==4.0.1" "beat_this==1.1.0" "soundfile>=0.12" "numpy<2" \
  einops rotary-embedding-torch pyyaml omegaconf julius tqdm
cp "$HERE"/{separate,fx,analyze}.py .
# effects stage (optional): model code pinned to a known commit, weights from the project's own release
if [[ ! -d msst ]]; then
  git clone --quiet https://github.com/ZFTurbo/Music-Source-Separation-Training msst
  git -C msst checkout --quiet 1f700c386e0dd763fe0a57242bb9420dce987354
fi
mkdir -p msst/weights
R=https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v.1.0.3
[[ -f msst/weights/bandit_plus_dnr.chpt ]] || curl -fL -o msst/weights/bandit_plus_dnr.chpt "$R/model_bandit_plus_dnr_sdr_11.47.chpt"
[[ -f msst/weights/config_dnr_bandit_bsrnn_multi_mus64.yaml ]] || curl -fL -o msst/weights/config_dnr_bandit_bsrnn_multi_mus64.yaml "$R/config_dnr_bandit_bsrnn_multi_mus64.yaml"
# warm-up: downloads the Demucs model and proves it runs
venv/bin/python - <<'PY'
import numpy as np, soundfile as sf
sr = 44100; t = np.arange(sr * 3) / sr
sf.write("warmup.wav", np.stack([np.sin(2*np.pi*440*t), np.sin(2*np.pi*660*t)], 1) * 0.3, sr)
PY
PYTORCH_ENABLE_MPS_FALLBACK=1 venv/bin/python separate.py warmup.wav warmup-out --shifts 1 --model htdemucs
rm -rf warmup.wav warmup-out
echo "Blend's AI tools are ready. Restart Blend."
