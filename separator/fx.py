# Blend effects stage: BandIt Plus (speech / music / effects, trained on the Divide and Remaster film-audio set)
# from ZFTurbo's Music-Source-Separation-Training (MIT), weights model_bandit_plus_dnr_sdr_11.47.chpt.
# usage: python fx.py <instrumentals.wav> <fx.wav> [--device mps|cpu] [--all <dir>]
# Writes the model's "effects" estimate. The app subtracts it from the instrumentals so the stems still add up to the song.
# Only the model code is used: the training libraries it imports (pytorch_lightning, librosa, spafe) are replaced by stubs.
import argparse, os, sys, time, types
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
import numpy as np, soundfile as sf, torch, yaml

HERE = os.path.dirname(os.path.abspath(__file__))
MSST = os.path.join(HERE, "msst")
CKPT = os.path.join(MSST, "weights", "bandit_plus_dnr.chpt")
CONF = os.path.join(MSST, "weights", "config_dnr_bandit_bsrnn_multi_mus64.yaml")
sys.path.insert(0, MSST)

def stub(name, **attrs):
    m = types.ModuleType(name); m.__dict__.update(attrs); sys.modules[name] = m; return m
stub("pytorch_lightning", LightningModule=torch.nn.Module)
stub("librosa", hz_to_midi=lambda f: 12 * (np.log2(np.asanyarray(f, dtype=float)) - np.log2(440.0)) + 69,
     midi_to_hz=lambda n: 440.0 * 2.0 ** ((np.asanyarray(n, dtype=float) - 69) / 12))
stub("spafe"); stub("spafe.fbanks", bark_fbanks=None); stub("spafe.utils")
stub("spafe.utils.converters", erb2hz=None, hz2bark=None, hz2erb=None)
for name in ["models", "models.bandit", "models.bandit.core"]:   # skip the training code in models/bandit/core/__init__.py
    stub(name, __path__=[os.path.join(MSST, *name.split("."))])
from models.bandit.core.model import MultiMaskMultiSourceBandSplitRNNSimple

ap = argparse.ArgumentParser()
ap.add_argument("input"); ap.add_argument("out")
ap.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
ap.add_argument("--all", default=None, help="also write speech / music / effects to this folder (for listening tests)")
ap.add_argument("--overlap", type=float, default=0.5, help="chunk overlap; keep 0.5: less overlap changes the result (tested 2026-11-17)")
ap.add_argument("--batch", type=int, default=8, help="chunks per GPU pass: same output, ~3x faster than one at a time")
a = ap.parse_args()

t0 = time.time()
cfg = yaml.safe_load(open(CONF))
model = MultiMaskMultiSourceBandSplitRNNSimple(**cfg["model"])
sd = torch.load(CKPT, map_location="cpu", weights_only=False)
if isinstance(sd, dict) and "state_dict" in sd: sd = sd["state_dict"]
sd = {k.replace("_orig_mod.", "").removeprefix("model."): v for k, v in sd.items()}
missing, unexpected = model.load_state_dict(sd, strict=False)
if missing: print(f"WARN missing {len(missing)} keys e.g. {missing[:3]}", file=sys.stderr)
model.eval().float().to(a.device)   # some band buffers are float64, which the Apple GPU can't hold
stems = cfg["model"]["stems"]
sr = cfg["audio"]["sample_rate"]

audio, rate = sf.read(a.input, dtype="float32", always_2d=True)
if rate != sr: sys.exit(f"expected {sr} Hz input, got {rate}")
x = torch.from_numpy(audio.T.copy())[:2]
if x.shape[0] == 1: x = x.repeat(2, 1)
n = x.shape[1]

# overlapping chunks with a raised-cosine crossfade, like the repo's demix()
C = cfg["audio"]["chunk_size"]; step = int(C * (1 - a.overlap)); fade = min(C // 10, C - step)
win = torch.ones(C); ramp = torch.linspace(0, 1, fade); win[:fade] = ramp; win[-fade:] = ramp.flip(0)
pad = C
xp = torch.nn.functional.pad(x, (pad, pad + C))
out = torch.zeros(len(stems), 2, xp.shape[1]); wsum = torch.zeros(xp.shape[1])
starts = list(range(0, xp.shape[1] - C + 1, step))
with torch.no_grad():
    for k0 in range(0, len(starts), a.batch):   # several chunks per GPU pass
        group = starts[k0:k0 + a.batch]
        ys = model(torch.stack([xp[:, s:s + C] for s in group]).to(a.device)).cpu()   # (batch, stems, channels, C)
        for s, y in zip(group, ys): out[:, :, s:s + C] += y * win; wsum[s:s + C] += win
        print(f"PROGRESS {min(1, (k0 + len(group)) / len(starts)):.2f}", flush=True)
out = (out / wsum.clamp(min=1e-6))[:, :, pad:pad + n]

fx = out[stems.index("effects")]
sf.write(a.out, fx.numpy().T, sr, subtype="FLOAT")
if a.all:
    os.makedirs(a.all, exist_ok=True)
    for name, s in zip(stems, out): sf.write(os.path.join(a.all, f"{name}.wav"), s.numpy().T, sr, subtype="FLOAT")
print(f"DONE bandit_plus {a.device} {n / sr:.1f}s audio in {time.time() - t0:.1f}s", flush=True)
