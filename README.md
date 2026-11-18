# Blend

A simple two-deck DJ mixer for macOS. Drop in two songs and Blend finds the beats, syncs the tempos and can mix from one song into the next for you. The look is a Windows 98 CD player.

Native Swift audio engine (AVAudioEngine) with the interface in a WebKit page. Analysis and stem splitting run locally on the Apple GPU, with no accounts, no cloud and no API keys.

## What it does

- **Two decks, one clock.** Both songs run inside one audio engine, so synced songs stay on the beat (within a few ms over minutes).
- **Analysis:** beats, downbeats, BPM, tempo map, key / Camelot (marked "unsure" when low confidence), energy sections (Intro / Build / Drop / Break / Main / Outro) and a 3-band waveform.
- **Sync and shared tempo:** the faster song slows to meet the slower one, and drop-ins land on the next downbeat.
- **Auto blend and Automix:** queue songs and Blend mixes each one into the next at its outro or a 16-bar line (8 / 16 / 32-bar blends, bass swap at halfway).
- **Crossfader Fusion:** Classic, Stem swap, Filter or Echo out.
- **Stems:** 5-part DJ split (vocals / drums / bass / melody / effects) with Demucs and BandIt Plus, cached per song.
- **Mashup: Vocal over Beat:** re-renders one song's stems to the other's tempo and key (ffmpeg rubberband) so a vocal sits beat-exact on another song's beat.
- **5-band parametric EQ per deck** in its own window, plus a filter and a beat-synced echo.
- **Scrubbing:** drag the waveform like a record.
- **Visualizers:** Blue Screen, Bars, Tunnel, plus an optional "Handycam" live cut that cuts your own video clips to the beat.
- **Recording:** mixes are recorded to `~/Music/Blend/Mixes`.

## Requirements

- macOS 13 or later on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- Optional, for analysis and stems: [uv](https://docs.astral.sh/uv/) and about 1 GB of disk
- Optional, for Mashup and Handycam: `ffmpeg` built with rubberband (Homebrew's `ffmpeg` includes it)

## Build

```sh
./build.sh            # builds build/Blend.app
./build.sh --install  # also copies it into /Applications
```

## Install the AI tools (analysis + stems)

```sh
zsh separator/setup.sh
```

This puts a Python 3.11 venv, PyTorch, Demucs, beat_this and the BandIt Plus effects model into `~/Library/Application Support/Blend/separator`. Delete that folder to remove them. Without it, Blend still plays and mixes, but nothing gets analysed or split.

## Where things live

- Library, analysis and stems: `~/Library/Application Support/Blend/` (songs are copied in; your originals are never touched)
- Recorded mixes: `~/Music/Blend/Mixes`

## Handycam visuals (optional)

`tools/handycam_proxies.py <folder>` makes small 4:3 proxies from a folder of video clips, organised in one sub-folder per theme. It writes them to `~/Library/Application Support/Blend/handycam/`, where the Handycam window picks them up. Originals are never touched.

## Tests

```sh
mkdir -p build/et && cp tests/engine_main.swift build/et/main.swift
swiftc -O -target arm64-apple-macos13.0 -o build/engine-tests build/et/main.swift engine/PDEngine.swift engine/PDMixer.swift engine/Separation.swift
./build/engine-tests
```

## Known limits

- Key detection is rough; about half of keys match published ones.
- Apple's time-stretcher is only beat-exact when slowing down, so a synced song is never sped up.
- No loops, sampler or flanger yet.

## Credits

- [Demucs](https://github.com/facebookresearch/demucs) (Meta, MIT): stem separation
- [beat_this](https://github.com/CPJKU/beat_this) (CPJKU, MIT): beat and downbeat tracking
- [Music-Source-Separation-Training](https://github.com/ZFTurbo/Music-Source-Separation-Training) (ZFTurbo, MIT): BandIt Plus effects model
- Fonts: VT323 and Share Tech Mono (SIL Open Font License)

## Licence

The code is MIT. The CPG logo and shirt artwork are not covered; see [LICENSE](LICENSE).
