# Makes Blend's live-visual proxies from the Handycam VHS library (originals are never touched).
# For each theme folder (client archive left out), picks up to N clips spread through the folder, cuts one 12 s moment
# from about a third of the way in, deinterlaces, squares the pixels to 640x480 (4:3), 24 fps, H.264, no audio.
# Writes ~/Library/Application Support/Blend/handycam/<theme>/<clip>.mp4 and index.json (served to the page).
# usage: python3 handycam_proxies.py <clip library folder> [per_theme=14]
# The library folder holds one sub-folder per theme; names listed in BLEND_SKIP (comma-separated) are left out.
import json, os, subprocess, sys
if len(sys.argv) < 2: sys.exit('usage: python3 handycam_proxies.py <clip library folder> [per_theme=14]')
SRC = os.path.expanduser(sys.argv[1])
OUT = os.path.expanduser('~/Library/Application Support/Blend/handycam')
SKIP = {s for s in os.environ.get('BLEND_SKIP', '').split(',') if s}
N = int(sys.argv[2]) if len(sys.argv) > 2 else 14
os.makedirs(OUT, exist_ok=True)
index, seen = [], set()
idx_path = os.path.join(OUT, 'index.json')
if os.path.exists(idx_path):
    index = json.load(open(idx_path)); seen = {c['source'] for c in index}
def dur(p):
    r = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', p], capture_output=True, text=True)
    try: return float(r.stdout.strip())
    except ValueError: return 0
for theme in sorted(os.listdir(SRC)):
    tdir = os.path.join(SRC, theme)
    if theme in SKIP or not os.path.isdir(tdir): continue
    files = sorted(f for f in os.listdir(tdir) if f.lower().endswith(('.mpg', '.mpeg', '.mov', '.mp4', '.m2ts', '.mts')))
    pick = [files[round(i * (len(files) - 1) / max(1, N - 1))] for i in range(min(N, len(files)))] if files else []
    os.makedirs(os.path.join(OUT, theme), exist_ok=True)
    for f in dict.fromkeys(pick):
        src = os.path.realpath(os.path.join(tdir, f))
        if src in seen: continue
        d = dur(src)
        if d < 2: continue
        start = max(0, min(d * 0.3, d - 12)); length = min(12, d - start)
        name = os.path.splitext(f)[0].lower().replace(' ', '_') + '.mp4'
        out = os.path.join(OUT, theme, name)
        r = subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{start:.2f}', '-t', f'{length:.2f}', '-i', src,
                            '-vf', 'yadif,scale=640:480:flags=lanczos,setsar=1,fps=24', '-an', '-c:v', 'libx264', '-preset', 'veryfast',
                            '-crf', '28', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(out): print('skip', f, r.stderr[-200:]); continue
        seen.add(src)
        index.append({'theme': theme, 'file': f'handycam/{theme}/{name}', 'name': os.path.splitext(f)[0].split(' - ')[-1].lower() + '.mpg',
                      'duration': round(length, 2), 'source': src})
        json.dump(index, open(idx_path, 'w'), indent=0)
        print(len(index), theme, name, flush=True)
print('done', len(index), 'clips')
