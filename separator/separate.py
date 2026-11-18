# Blend AI separation runner: Demucs htdemucs_ft (MIT) on the Apple GPU, high-quality settings.
# usage: python separate.py <input.wav> <out_dir> [--shifts N] [--overlap F] [--device mps|cpu]
# Writes vocals.wav, drums.wav, bass.wav, other.wav (32-bit float, 44.1 kHz stereo) and prints progress lines "PROGRESS 0.42".
# Calls the model directly and saves with soundfile, so it doesn't depend on torchaudio's file backends.
import argparse, os, sys, time
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
import numpy as np, soundfile as sf, torch
from demucs.pretrained import get_model
from demucs.apply import apply_model
import julius

ap = argparse.ArgumentParser()
ap.add_argument("input"); ap.add_argument("out")
ap.add_argument("--model", default="htdemucs_ft")
ap.add_argument("--shifts", type=int, default=2)      # random time-shift passes averaged together: cleaner, slower
ap.add_argument("--overlap", type=float, default=0.5)  # overlap between chunks: fewer seams
ap.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
a = ap.parse_args()

t0 = time.time()
model = get_model(a.model); model.eval()
audio, sr = sf.read(a.input, dtype="float32", always_2d=True)          # (frames, channels)
wav = torch.from_numpy(audio.T.copy())
if wav.shape[0] == 1: wav = wav.repeat(2, 1)
wav = wav[:2]
if sr != model.samplerate: wav = julius.resample_frac(wav, sr, model.samplerate)
ref = wav.mean(0); mean, std = ref.mean(), ref.std() + 1e-8
x = (wav - mean) / std

# apply_model runs each of htdemucs_ft's four specialist models; report progress per model
models = getattr(model, "models", [model])
print(f"PROGRESS 0.02", flush=True)
with torch.no_grad():
    out = apply_model(model, x[None], device=a.device, shifts=a.shifts, split=True, overlap=a.overlap, progress=False)[0]
out = out * std + mean
os.makedirs(a.out, exist_ok=True)
for name, src in zip(model.sources, out):
    sf.write(os.path.join(a.out, f"{name}.wav"), src.cpu().numpy().T, model.samplerate, subtype="FLOAT")
print(f"PROGRESS 1.0", flush=True)
print(f"DONE {a.model} {a.device} shifts={a.shifts} overlap={a.overlap} {time.time() - t0:.1f}s", flush=True)
