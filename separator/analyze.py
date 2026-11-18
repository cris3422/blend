# Song analysis for Blend: beats, downbeats, BPM, tempo map, key, sections and a 3-band waveform.
# usage: python analyze.py <input.wav> <out.json> [--device mps|cpu]
# Beats/downbeats: beat_this (CPJKU, MIT). Key: chroma + Krumhansl-Kessler profiles. Sections: bar-level novelty, snapped
# to 4/8-bar grid, labelled by energy (Intro / Build / Drop / Break / Main / Outro) - honest heuristics, not verse/chorus.
import argparse, json, os, sys, time
import numpy as np, soundfile as sf, torch

ap = argparse.ArgumentParser()
ap.add_argument("input"); ap.add_argument("out")
ap.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
a = ap.parse_args()
t0 = time.time()
P = lambda p: print(f"PROGRESS {p:.2f}", flush=True)

audio, sr = sf.read(a.input, dtype="float32", always_2d=True)
mono = audio.mean(1)
dur = len(mono) / sr
P(0.05)

# ---------- beats + downbeats ----------
from beat_this.inference import Audio2Beats
try:
    beats, downs = Audio2Beats(checkpoint_path="final0", device=a.device)(mono, sr)
except Exception as e:   # MPS can miss an op; CPU always works
    print(f"beat_this on {a.device} failed ({e}); using cpu", file=sys.stderr)
    beats, downs = Audio2Beats(checkpoint_path="final0", device="cpu")(mono, sr)
beats = np.asarray(beats, float); downs = np.asarray(downs, float)
P(0.55)

def fold(b):   # keep BPM in 70-180: trackers sometimes count half or double time
    while b < 70: b *= 2
    while b > 180: b /= 2
    return b

if len(beats) >= 8:
    ibi = np.diff(beats)
    med = float(np.median(ibi))
    bpm = fold(60 / med)
    spread = float(np.median(np.abs(ibi - med)) / med)          # typical beat-to-beat wobble, as a fraction
    bpm_conf = float(np.clip(1 - spread * 20, 0, 1))            # 0% wobble -> 1, 5% -> 0
    # local tempo per 8 bars (32 beats)
    tmap = []
    for i in range(0, len(beats) - 1, 32):
        seg = ibi[i:i + 32]
        if len(seg) >= 4: tmap.append([round(float(beats[i]), 3), round(fold(60 / float(np.median(seg))), 2)])
    stable = all(abs(b - bpm) / bpm < 0.015 for _, b in tmap)
else:
    bpm, bpm_conf, tmap, stable = 0.0, 0.0, [], False

# ---------- spectrum frames (shared by key, sections, waveform) ----------
hop = int(sr / 100); n_fft = 4096
win = np.hanning(n_fft).astype(np.float32)
pad = np.concatenate([np.zeros(n_fft // 2, np.float32), mono, np.zeros(n_fft, np.float32)])
nfr = int(np.ceil(len(mono) / hop))
freqs = np.fft.rfftfreq(n_fft, 1 / sr)
low_b, mid_b, high_b = freqs < 250, (freqs >= 250) & (freqs < 4000), freqs >= 4000
# pitch-class map for chroma (60 Hz - 5 kHz)
valid = (freqs >= 60) & (freqs <= 5000)
pc = np.full(len(freqs), -1)
pc[valid] = (np.round(12 * np.log2(freqs[valid] / 440.0)) + 9).astype(int) % 12   # 0 = C
wl = np.zeros(nfr, np.float32); wm = np.zeros(nfr, np.float32); wh = np.zeros(nfr, np.float32)
rms = np.zeros(nfr, np.float32); cent = np.zeros(nfr, np.float32)
chroma_frames = np.zeros((nfr, 12), np.float32)
B = 512
for s in range(0, nfr, B):
    idx = np.arange(s, min(nfr, s + B))
    fr = np.stack([pad[i * hop:i * hop + n_fft] for i in idx]) * win
    mag = np.abs(np.fft.rfft(fr, axis=1)).astype(np.float32)
    pw = mag ** 2
    wl[idx] = np.sqrt(pw[:, low_b].sum(1)); wm[idx] = np.sqrt(pw[:, mid_b].sum(1)); wh[idx] = np.sqrt(pw[:, high_b].sum(1))
    rms[idx] = np.sqrt(pw.sum(1))
    cent[idx] = (pw * freqs).sum(1) / (pw.sum(1) + 1e-9)
    if s % 8 == 0 or True:
        for k in range(12): chroma_frames[idx, k] = mag[:, pc == k].sum(1)
    P(0.55 + 0.3 * min(1, (s + B) / nfr))

# ---------- key ----------
KK_MAJ = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
KK_MIN = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
# Camelot: major keys (B), minor keys (A), by tonic pitch class
CAM_MAJ = {0: "8B", 7: "9B", 2: "10B", 9: "11B", 4: "12B", 11: "1B", 6: "2B", 1: "3B", 8: "4B", 3: "5B", 10: "6B", 5: "7B"}
CAM_MIN = {9: "8A", 4: "9A", 11: "10A", 6: "11A", 1: "12A", 8: "1A", 3: "2A", 10: "3A", 5: "4A", 0: "5A", 7: "6A", 2: "7A"}
# key chroma: its own pass with fine frequency resolution (16384-point FFT every 0.1 s). Each musical note (E2..C8)
# takes the PEAK magnitude inside its own +-half-semitone band, so pitch classes with more FFT bins aren't favoured;
# notes are then folded into 12 pitch classes, frames weighted by loudness.
kn = 16384; khop = int(sr / 10); kwin = np.hanning(kn).astype(np.float32)
kf = np.fft.rfftfreq(kn, 1 / sr)
notes = np.arange(48, 97)                                   # MIDI 48 (C3, 131 Hz) .. 96 (C7): skips 808 sub-bass and cymbal hiss
fc = 440.0 * 2 ** ((notes - 69) / 12)
lo_i = np.searchsorted(kf, fc * 2 ** (-0.5 / 12)); hi_i = np.maximum(lo_i + 1, np.searchsorted(kf, fc * 2 ** (0.5 / 12)))
npc = notes % 12                                            # MIDI % 12: 0 = C
c_acc = np.zeros(12)
starts = list(range(0, max(1, len(mono) - kn), khop))
for k0 in range(0, len(starts), 64):
    fr = np.stack([mono[i:i + kn] * kwin for i in starts[k0:k0 + 64]])
    mag = np.abs(np.fft.rfft(fr, axis=1))
    for row in mag:
        pk = np.array([row[a0:a1].max() for a0, a1 in zip(lo_i, hi_i)])
        pk = np.sqrt(pk)                                    # soften loud notes
        v = np.bincount(npc, weights=pk, minlength=12)
        e = v.sum()
        if e > 0: c_acc += v / e * e ** 0.5
c = c_acc / (c_acc.sum() + 1e-9)
scores = []
for t in range(12):
    scores.append((np.corrcoef(c, np.roll(KK_MAJ, t))[0, 1], t, "major"))
    scores.append((np.corrcoef(c, np.roll(KK_MIN, t))[0, 1], t, "minor"))
scores.sort(reverse=True)
(best, tonic, mode), second = scores[0], scores[1][0]
key = f"{NAMES[tonic]} {mode}"
camelot = (CAM_MAJ if mode == "major" else CAM_MIN)[tonic]
key_conf = float(np.clip((best - second) / 0.15, 0, 1))

# ---------- sections (bar level) ----------
sections = []
bars = downs if len(downs) >= 8 else (beats[::4] if len(beats) >= 32 else np.array([]))
if len(bars) >= 8:
    edges = np.append(bars, dur)
    fi = lambda t: min(nfr - 1, int(t * 100))
    feats, energy = [], []
    for i in range(len(bars)):
        a0, a1 = fi(edges[i]), max(fi(edges[i]) + 1, fi(edges[i + 1]))
        e = float(rms[a0:a1].mean()); lo = float(wl[a0:a1].mean())
        ch = chroma_frames[a0:a1].mean(0); ch = ch / (ch.sum() + 1e-9)
        feats.append(np.concatenate([[np.log1p(e), np.log1p(lo), cent[a0:a1].mean() / 4000], ch]))
        energy.append(e)
    F = np.array(feats); F = (F - F.mean(0)) / (F.std(0) + 1e-9)
    energy = np.array(energy)
    # novelty: difference between the 4 bars before and after each bar line
    nov = np.zeros(len(bars))
    for i in range(4, len(bars) - 4): nov[i] = np.linalg.norm(F[i:i + 4].mean(0) - F[i - 4:i].mean(0))
    # candidate boundaries every 4 bars, prefer 8; keep the strongest, at least 8 bars apart
    cands = sorted([i for i in range(8, len(bars) - 7) if i % 4 == 0], key=lambda i: -(nov[i] * (1.15 if i % 8 == 0 else 1)))
    thr = np.percentile(nov[nov > 0], 70) if (nov > 0).any() else 0
    chosen = []
    for i in cands:
        if nov[i] < thr: break
        if all(abs(i - j) >= 8 for j in chosen): chosen.append(i)
    cuts = [0] + sorted(chosen) + [len(bars)]
    segs = [(cuts[k], cuts[k + 1]) for k in range(len(cuts) - 1)]
    en = np.array([energy[s:e].mean() for s, e in segs])
    norm = (en - en.min()) / (en.max() - en.min() + 1e-9)
    med = np.median(en)
    labels = []
    for k, (s, e) in enumerate(segs):
        hi = norm[k] > 0.66; lo = norm[k] < 0.33
        if k == 0 and en[k] < med: lab = "Intro"
        elif k == len(segs) - 1 and en[k] < med: lab = "Outro"
        elif hi and k > 0 and en[k - 1] < en[k] * 0.85: lab = "Drop"
        elif lo: lab = "Break"
        elif k + 1 < len(segs) and norm[k + 1] > 0.66 and en[k + 1] > en[k] * 1.15: lab = "Build"
        else: lab = "Main"
        labels.append(lab)
    for (s, e), lab, nv in zip(segs, labels, norm):
        sections.append({"start": round(float(edges[s]), 3), "end": round(float(edges[e]), 3), "label": lab, "energy": round(float(nv), 3), "bars": int(e - s)})

# neighbours with the same label read as one section
merged = []
for sct in sections:
    if merged and merged[-1]["label"] == sct["label"]:
        m = merged[-1]; tot = m["bars"] + sct["bars"]
        m["energy"] = round((m["energy"] * m["bars"] + sct["energy"] * sct["bars"]) / tot, 3); m["end"] = sct["end"]; m["bars"] = tot
    else: merged.append(dict(sct))
sections = merged

# ---------- waveform (0-255 per band, 100 points a second) ----------
def q(x):
    top = np.percentile(x, 99.5) + 1e-9
    return np.clip(np.round(255 * np.sqrt(np.clip(x / top, 0, 1))), 0, 255).astype(int).tolist()
n100 = int(round(dur * 100))
out = {
    "version": 1, "duration": round(dur, 3), "bpm": round(bpm, 2), "bpm_confidence": round(bpm_conf, 3),
    "beats": [round(float(x), 4) for x in beats], "downbeats": [round(float(x), 4) for x in downs],
    "first_downbeat": round(float(downs[0]), 4) if len(downs) else (round(float(beats[0]), 4) if len(beats) else 0.0),
    "tempo_stable": bool(stable), "tempo_map": tmap,
    "key": key, "camelot": camelot, "key_confidence": round(key_conf, 3),
    "sections": sections,
    "waveform": {"rate": 100, "low": q(wl[:n100]), "mid": q(wm[:n100]), "high": q(wh[:n100])},
    "analysis_seconds": round(time.time() - t0, 1),
}
with open(a.out, "w") as f: json.dump(out, f, separators=(",", ":"))
P(1.0)
print(f"DONE bpm {out['bpm']} key {key} ({camelot}) {len(beats)} beats {len(sections)} sections in {out['analysis_seconds']}s", flush=True)
