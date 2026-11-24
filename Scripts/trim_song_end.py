#!/usr/bin/env python3
"""End a song cleanly before a broken stretch (the Plain Loop II fix, as a script).

Keeps the audio from 0 up to a bar line before `--before` unchanged (bit for bit), fades out
over the bar before that line (raised cosine 0.5 * (1 + cos(pi * (i + 0.5) / N))) and stops
5 ms before the low-band attack (kick) of the bar line, so no partial hit is left at the end.

Bar lines come from the loop analysis grid (`--bar-seconds`, `--anchor`); each is moved to the
strongest low-band attack within 80 ms, because these Suno tracks drift a little against any
single grid. Writes a 24-bit WAV and a provenance.json next to it.

    .venv-audio/bin/python Scripts/trim_song_end.py SOURCE OUTPUT --before 233.2 \
        --bar-seconds 2.400077 --anchor 20.0918 --why "..."
"""

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt

ATTACK_SEARCH_SECONDS = 0.08
CUT_BEFORE_ATTACK_SECONDS = 0.005


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def low_band_flux(mono: np.ndarray, rate: int) -> np.ndarray:
    """Positive change of the < 150 Hz level per 1 ms (kick attacks)."""
    low = sosfilt(butter(4, 150, "low", fs=rate, output="sos"), mono)
    hop = rate // 1000
    frames = len(low) // hop
    level = 10 * np.log10((low[: frames * hop].reshape(frames, hop) ** 2).mean(axis=1) + 1e-12)
    smooth = np.convolve(level, np.ones(5) / 5, mode="same")
    return np.maximum(0.0, np.diff(smooth, prepend=smooth[0]))


def attack_near(flux: np.ndarray, seconds: float) -> tuple:
    """Strongest low-band attack within ATTACK_SEARCH_SECONDS of `seconds` (time, strength)."""
    centre = int(round(seconds * 1000))
    reach = int(ATTACK_SEARCH_SECONDS * 1000)
    lo, hi = max(0, centre - reach), min(len(flux), centre + reach + 1)
    index = lo + int(np.argmax(flux[lo:hi]))
    return index / 1000.0, float(flux[index])


def trim_end(source: Path, output: Path, before: float, bar_seconds: float, anchor: float, why: str = "") -> dict:
    """Writes `output` (24-bit WAV or FLAC by its extension) and `output`'s provenance JSON next
    to it; returns the provenance."""
    args = argparse.Namespace(source=Path(source), output=Path(output), before=before, bar_seconds=bar_seconds,
                              anchor=anchor, why=why)
    info = sf.info(str(args.source))
    data, rate = sf.read(str(args.source), dtype="int32", always_2d=True)  # 16-bit values << 16
    mono = data.mean(axis=1) / 2147483648.0
    flux = low_band_flux(mono, rate)

    # Bar lines of the grid at or before `--before`, nearest first; each refined to its attack.
    k = int(np.floor((args.before - args.anchor) / args.bar_seconds))
    chosen = None
    for step in range(0, 6):
        predicted = args.anchor + (k - step) * args.bar_seconds
        attack, strength = attack_near(flux, predicted)
        if attack <= args.before and strength > 1.0:
            previous_predicted = predicted - args.bar_seconds
            previous_attack, previous_strength = attack_near(flux, previous_predicted)
            chosen = (predicted, attack, strength, previous_predicted, previous_attack, previous_strength)
            break
    if chosen is None:
        raise SystemExit("no bar line with a low-band attack before --before")
    predicted, attack, strength, previous_predicted, previous_attack, previous_strength = chosen

    end_frame = int(round((attack - CUT_BEFORE_ATTACK_SECONDS) * rate))
    fade_start = int(round((previous_attack - CUT_BEFORE_ATTACK_SECONDS) * rate)) if previous_strength > 1.0 \
        else end_frame - int(round(args.bar_seconds * rate))
    length = end_frame - fade_start
    out = data[:end_frame].astype(np.float64)
    i = np.arange(length)
    gain = 0.5 * (1 + np.cos(np.pi * (i + 0.5) / length))
    out[fade_start:end_frame] *= gain[:, None]
    # Source is 16-bit: its values are exact multiples of 65536 here; 24-bit keeps the kept part
    # bit-identical and gives the fade 8 more bits.
    out24 = np.round(out / 256.0).astype(np.int32)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    kind = "FLAC" if args.output.suffix.lower() == ".flac" else "WAV"
    sf.write(str(args.output), out24 * 256, rate, subtype="PCM_24", format=kind)

    check, _ = sf.read(str(args.output), dtype="int32", always_2d=True)
    kept_identical = bool(np.array_equal(check[:fade_start] >> 16, data[:fade_start] >> 16))
    provenance = {
        "path": str(args.output.resolve()),
        "sha256": sha256(args.output),
        "createdAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "source": {"path": str(args.source.resolve()), "sha256": sha256(args.source), "frames": int(info.frames),
                   "sampleRate": int(rate), "channels": int(info.channels),
                   "durationSeconds": info.frames / rate, "sourceSubtype": info.subtype},
        "why": args.why,
        "kept": {"startSeconds": 0.0, "endSeconds": end_frame / rate, "endFrame": end_frame,
                 "endRule": "5 ms before the low-band attack of the last grid bar line at or before {} s".format(args.before)},
        "fadeOut": {"startSeconds": fade_start / rate, "startFrame": fade_start, "lengthSeconds": length / rate,
                    "shape": "raised cosine 0.5*(1+cos(pi*(i+0.5)/N)), applied to the source values"},
        "barLine": {"barSeconds": args.bar_seconds, "anchorSeconds": args.anchor,
                    "predictedSeconds": [previous_predicted, predicted],
                    "lowBandAttackSeconds": [previous_attack, attack],
                    "attackStrengthDb": [round(previous_strength, 2), round(strength, 2)]},
        "output": {"format": kind, "subtype": "PCM_24", "frames": end_frame, "durationSeconds": end_frame / rate,
                   "keptPartBitIdentical": kept_identical},
        "otherProcessing": "none (no gain change, no resampling, no filtering)",
        "script": "Scripts/trim_song_end.py",
    }
    (args.output.parent / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return provenance


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--before", type=float, required=True, help="the broken stretch starts here (s)")
    parser.add_argument("--bar-seconds", type=float, required=True)
    parser.add_argument("--anchor", type=float, required=True, help="a bar line of the loop grid (s)")
    parser.add_argument("--why", default="")
    args = parser.parse_args()
    provenance = trim_end(args.source, args.output, args.before, args.bar_seconds, args.anchor, args.why)
    print(json.dumps({"keptEnd": round(provenance["kept"]["endSeconds"], 3),
                      "fadeStart": round(provenance["fadeOut"]["startSeconds"], 3),
                      "barAttacks": [round(x, 3) for x in provenance["barLine"]["lowBandAttackSeconds"]],
                      "keptIdentical": provenance["output"]["keptPartBitIdentical"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
