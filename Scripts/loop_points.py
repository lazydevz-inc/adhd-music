#!/usr/bin/env python3
"""Find the repeatable middle of a track: loop points for "each track plays for 30 min".

Example::
    .venv-audio/bin/python Scripts/loop_points.py <audio> --bpm 120.0028 --offset 0.1177
    .venv-audio/bin/python Scripts/loop_points.py --self-test

The app repeats [loopStart, loopEnd) with a SEAM_SECONDS equal-power crossfade centred on each
seam (FocusRenderCore.loopSeamSeconds), so both points must sit on the same beat of the same
kind of bar. Steps:

1. Body: short-term loudness (BS.1770 K-weighting, 3 s) against the body level (median of the
   middle 60 %). The loop stays between the first and last time the music reaches body - 2 dB,
   so the intro and the fade-out or ending are skipped. It never spans a dropout (0.5 s or more
   at -60 dBFS or below) or anything after `avoid_after` (a catalog flag such as "gaps"), and
   with `avoid_breaks` (version 2) not a short silence (0.25 s or more), a drop of 6 s or more
   (short-term loudness 10 LU under the body, or the low band 20 dB under its body level: the
   drums and bass stop) or any of `avoid_ranges` (the library build passes beat-map stretches
   where the beat is loose or the drums stop), because the loop repeats every 30-minute pass.
2. Bars: the beat grid (bpm, offset) gives the bar length; a tempo map (onset autocorrelation
   at the bar lag every 5 s) follows slow tempo drift, which several generated tracks have, so
   bar lines far apart still line up. The downbeat is the beat phase with the most chord change
   and low-band attack.
3. Candidates: every pair of bar lines at least MIN_LOOP_BEATS apart inside the body. loopEnd is
   refined within +-REFINE_MS by cross-correlating the onset envelope just after loopEnd (scaled
   to loopStart's tempo) against the one just after loopStart, so drums do not flam, to a
   fraction of a millisecond.
4. A seam passes when the music on both sides matches: chroma and spectrum over two bars, the
   onset pattern (relative to the track's own bar-to-bar similarity), loudness within 2 dB, the
   onsets inside the 1 s seam itself line up within 3 ms (both sides are heard there), and the
   two sides' waveforms over the seam do not cancel (K-weighted correlation r >= -0.3).
   r is written as loopSeamCorrelation: the engine keeps the seam's power flat for it (plain
   cos/sin gains would swell by 10 log10(1 + r) dB mid-seam when well-aligned drums coincide).
   The pick favours the longest loop, then the best match and whole 4-bar phrases. No passing
   pair: no loop points.

Numbers are acoustic similarity measures, not a listening test.
"""

import argparse
import json
import math
from pathlib import Path
import sys
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
from scipy import signal
from scipy.ndimage import median_filter
import soundfile as sf

LOOP_VERSION = 2
SEAM_SECONDS = 1.0          # FocusRenderCore.loopSeamSeconds
MIN_LOOP_BEATS = 32
BEATS_PER_BAR = 4
REFINE_MS = 60
PHRASE_BONUS = 0.15
BODY_DROP_DB = 2.0
DROPOUT_DBFS = -60.0
DROPOUT_SECONDS = 0.5
SHORT_SILENCE_SECONDS = 0.25   # version 2: a shorter silence still blocks the loop
BREAK_SECONDS = 5.0            # version 2: a drop this long is a break, not a phrase-end pause (3-4 s)
BREAK_LEVEL_LU = 10.0
BREAK_LOW_DB = 20.0
ENVELOPE_RATE = 1000        # onset envelope samples per second (1 ms)
FEATURE_HOP = 0.1           # loudness, chroma and spectrum frames (s)
MAX_STARTS = 16
TEMPO_DRIFT_LIMIT = 0.03    # local bar length within +-3 % of the grid's
THRESHOLDS = {"chroma": 0.90, "spectrum": 0.90, "loudnessDb": 2.0, "seamCorrelationFloor": -0.3,
              "seamOnsetLagMs": 3, "onsetFloor": 0.08, "onsetRelative": 0.6}
SEAM_LAG_SEARCH_MS = 30
SEAM_CORRELATION_RANGE = (-0.3, 0.9)   # FocusLoopPlan clamps to the same range


def k_weighting(sample_rate: float) -> np.ndarray:
    """BS.1770 pre-filter (shelf + high-pass) as second-order sections for any sample rate."""
    gain_db, q, centre = 3.999843853973347, 0.7071752369554196, 1681.974450955533
    k = math.tan(math.pi * centre / sample_rate)
    vh = 10 ** (gain_db / 20.0)
    vb = vh ** 0.4996667741545416
    a0 = 1.0 + k / q + k * k
    shelf = [(vh + vb * k / q + k * k) / a0, 2.0 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
             1.0, 2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0]
    q2, centre2 = 0.5003270373238773, 38.13547087602444
    k2 = math.tan(math.pi * centre2 / sample_rate)
    a02 = 1.0 + k2 / q2 + k2 * k2
    high = [1.0, -2.0, 1.0, 1.0, 2.0 * (k2 * k2 - 1.0) / a02, (1.0 - k2 / q2 + k2 * k2) / a02]
    return np.array([shelf, high])


def loudness_curves(audio: np.ndarray, rate: int) -> Tuple[np.ndarray, np.ndarray]:
    """Centred short-term (3 s) and momentary (0.4 s) loudness in LUFS, one value per FEATURE_HOP."""
    weighted = signal.sosfilt(k_weighting(rate), audio, axis=0)
    power = np.sum(weighted * weighted, axis=1)
    hop = int(round(FEATURE_HOP * rate))
    blocks = power[:len(power) // hop * hop].reshape(-1, hop).mean(axis=1)

    def smooth(seconds: float) -> np.ndarray:
        width = max(1, int(round(seconds / FEATURE_HOP)))
        mean = np.convolve(blocks, np.ones(width) / width, mode="same")
        return -0.691 + 10 * np.log10(np.maximum(mean, 1e-12))
    return smooth(3.0), smooth(0.4)


def dropouts(audio: np.ndarray, rate: int) -> List[Tuple[float, float]]:
    """(start, end) seconds of runs of at least DROPOUT_SECONDS at or below DROPOUT_DBFS."""
    hop = int(round(0.05 * rate))
    count = len(audio) // hop
    power = (audio[:count * hop] ** 2).mean(axis=1).reshape(count, hop).mean(axis=1)
    quiet = 10 * np.log10(power + 1e-20) <= DROPOUT_DBFS
    runs, index = [], 0
    while index < count:
        if quiet[index]:
            end = index
            while end < count and quiet[end]:
                end += 1
            if (end - index) * 0.05 >= DROPOUT_SECONDS:
                runs.append((index * 0.05, end * 0.05))
            index = end
        else:
            index += 1
    return runs


def onset_envelope(mono: np.ndarray, rate: int) -> np.ndarray:
    """Sum of three bands' rising log-energy (3 ms lag), each scaled by its 99th percentile, at
    1 kHz. Kick, snare and hats; 150-800 Hz is left out because sustained chords there beat and
    read as attacks."""
    hop = max(1, int(round(rate / ENVELOPE_RATE)))
    total = None
    for low, high in [(30, 150), (800, 4000), (4000, 15000)]:
        high = min(high, 0.45 * rate)
        if high <= low * 1.2:
            continue
        band = signal.sosfilt(signal.butter(4, [low, high], btype="bandpass", fs=rate, output="sos"), mono)
        energy = (band[:len(band) // hop * hop] ** 2).reshape(-1, hop).mean(axis=1)
        energy = np.convolve(energy, np.ones(3) / 3, mode="same")
        level = np.log10(energy + 1e-10)
        rise = np.zeros_like(level)
        rise[3:] = np.maximum(level[3:] - level[:-3], 0)
        rise /= np.percentile(rise, 99) + 1e-9
        total = rise if total is None else total + rise
    return total


def chroma_and_spectrum(mono: np.ndarray, rate: int) -> Tuple[np.ndarray, np.ndarray]:
    """Per FEATURE_HOP frame: 12 pitch-class energies (65 Hz-2 kHz) and 24 log band energies."""
    size = 1 << int(math.ceil(math.log2(0.17 * rate)))
    hop = int(round(FEATURE_HOP * rate))
    padded = np.pad(mono, (size // 2, size // 2))
    frames = 1 + (len(padded) - size) // hop
    window = np.hanning(size)
    freqs = np.fft.rfftfreq(size, 1 / rate)
    pitched = (freqs >= 65) & (freqs <= 2000)
    pitch_class = np.round(12 * np.log2(freqs[pitched] / 440.0)).astype(int) % 12
    edges = np.geomspace(40, min(16000, 0.45 * rate), 25)
    band_of = np.digitize(freqs, edges) - 1
    chroma = np.zeros((12, frames))
    spectrum = np.zeros((24, frames))
    for first in range(0, frames, 256):
        last = min(frames, first + 256)
        block = np.stack([padded[k * hop:k * hop + size] for k in range(first, last)]) * window
        power = np.abs(np.fft.rfft(block, axis=1)) ** 2
        selected = power[:, pitched]
        for pc in range(12):
            chroma[pc, first:last] = selected[:, pitch_class == pc].sum(axis=1)
        for band in range(24):
            spectrum[band, first:last] = np.log10(power[:, band_of == band].sum(axis=1) + 1e-9)
    return chroma, spectrum


def bar_periods(envelope: np.ndarray, grid_bar: float, step: float = 5.0, window: float = 16.0) -> np.ndarray:
    """Rows (centre s, bar length s, peak correlation): onset autocorrelation near the grid's bar."""
    width = int(window * ENVELOPE_RATE)
    centre_lag = grid_bar * ENVELOPE_RATE
    span = max(2, int(TEMPO_DRIFT_LIMIT * centre_lag))
    lags = np.arange(int(centre_lag) - span, int(centre_lag) + span + 1)
    rows = []
    duration = len(envelope) / ENVELOPE_RATE
    for centre in np.arange(window / 2, duration - window / 2 + 1e-9, step):
        start = int((centre - window / 2) * ENVELOPE_RATE)
        x = envelope[start:start + width] - envelope[start:start + width].mean()
        values = np.array([np.dot(x[:-lag], x[lag:]) / (np.linalg.norm(x[:-lag]) * np.linalg.norm(x[lag:]) + 1e-12)
                           for lag in lags])
        best = int(np.argmax(values))
        shift = 0.0
        if 0 < best < len(values) - 1:
            curvature = values[best - 1] - 2 * values[best] + values[best + 1]
            if curvature != 0:
                shift = 0.5 * (values[best - 1] - values[best + 1]) / curvature
        rows.append((centre, (lags[best] + shift) / ENVELOPE_RATE, values[best]))
    if not rows:
        rows.append((duration / 2, grid_bar, 0.0))
    table = np.array(rows)
    lengths = median_filter(table[:, 1], size=3, mode="nearest")
    table[:, 1] = np.convolve(np.pad(lengths, 2, mode="edge"), np.ones(5) / 5, mode="valid")
    table[:, 1] = np.clip(table[:, 1], grid_bar * (1 - TEMPO_DRIFT_LIMIT), grid_bar * (1 + TEMPO_DRIFT_LIMIT))
    return table


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    norm = float(np.linalg.norm(a) * np.linalg.norm(b))
    return float(np.dot(a, b) / norm) if norm > 0 else 0.0


def pearson(a: np.ndarray, b: np.ndarray) -> float:
    return cosine(a - a.mean(), b - b.mean())


def shifted_ncc(reference: np.ndarray, segment: np.ndarray) -> np.ndarray:
    """Normalized cross-correlation of `reference` with every window of `segment`."""
    windows = sliding_window_view(segment, len(reference))
    centred = windows - windows.mean(axis=1, keepdims=True)
    ref = reference - reference.mean()
    norms = np.linalg.norm(centred, axis=1) * np.linalg.norm(ref)
    products = np.einsum("ij,j->i", centred, ref)
    return np.where(norms > 0, products / np.maximum(norms, 1e-12), 0.0)


def breaks(audio: np.ndarray, rate: int, short_term: np.ndarray, body: float,
           body_range: Tuple[float, float]) -> List[Tuple[float, float, str]]:
    """Version 2 blocks: short silences, and drops of BREAK_SECONDS or more where the short-term
    loudness falls BREAK_LEVEL_LU under the body or the low band (< 150 Hz) BREAK_LOW_DB under its
    body level (1 s smoothing). (start, end, reason) in seconds."""
    found: List[Tuple[float, float, str]] = []
    hop = int(round(0.05 * rate))
    count = len(audio) // hop
    power = (audio[:count * hop] ** 2).mean(axis=1).reshape(count, hop).mean(axis=1)
    quiet = 10 * np.log10(power + 1e-20) <= DROPOUT_DBFS
    index = 0
    while index < count:
        if quiet[index]:
            end = index
            while end < count and quiet[end]:
                end += 1
            if (end - index) * 0.05 >= SHORT_SILENCE_SECONDS:
                found.append((index * 0.05, end * 0.05, "silence"))
            index = end
        else:
            index += 1
    mono = audio.mean(axis=1)
    low = signal.sosfilt(signal.butter(4, 150, "low", fs=rate, output="sos"), mono)
    step = int(round(FEATURE_HOP * rate))
    frames = len(low) // step
    low_db = 10 * np.log10((low[:frames * step] ** 2).reshape(frames, step).mean(axis=1) + 1e-20)
    low_db = 10 * np.log10(np.convolve(10 ** (low_db / 10), np.ones(10) / 10, mode="same"))
    a, b = int(body_range[0] / FEATURE_HOP), int(body_range[1] / FEATURE_HOP)
    low_body = float(np.median(low_db[a:b])) if b > a else float(np.median(low_db))
    n = min(len(short_term), len(low_db))
    weak = (short_term[:n] < body - BREAK_LEVEL_LU) | (low_db[:n] < low_body - BREAK_LOW_DB)
    index = 0
    while index < n:
        if weak[index]:
            end = index
            while end < n and weak[end]:
                end += 1
            if (end - index) * FEATURE_HOP >= BREAK_SECONDS:
                found.append((index * FEATURE_HOP, end * FEATURE_HOP, "drop"))
            index = end
        else:
            index += 1
    return found


def analyze_loop(path: Path, bpm: Optional[float], beat_offset: Optional[float],
                 avoid_after: Optional[float] = None, avoid_ranges: Optional[List[Tuple[float, float]]] = None,
                 avoid_breaks: bool = True) -> Dict[str, Any]:
    """Loop points for one file. Returns loopStartSeconds/loopEndSeconds/loopBars/
    loopSeamCorrelation (all None when no seam passes) and `detail` with the measurements."""
    result: Dict[str, Any] = {"loopStartSeconds": None, "loopEndSeconds": None, "loopBars": None,
                              "loopSeamCorrelation": None,
                              "detail": {"version": LOOP_VERSION, "seamSeconds": SEAM_SECONDS,
                                         "thresholds": THRESHOLDS, "minimumBeats": MIN_LOOP_BEATS}}
    detail = result["detail"]
    if not bpm or not math.isfinite(bpm) or bpm <= 0:
        detail["reason"] = "no tempo estimate"
        return result
    audio, rate = sf.read(str(path), dtype="float64", always_2d=True)
    mono = audio.mean(axis=1)
    duration = len(mono) / rate
    beat = 60.0 / bpm
    grid_bar = BEATS_PER_BAR * beat
    half = SEAM_SECONDS / 2

    short_term, momentary = loudness_curves(audio, rate)
    middle = short_term[int(0.2 * len(short_term)):int(0.8 * len(short_term))]
    body = float(np.median(middle)) if len(middle) else float(np.median(short_term))
    reached = np.where(short_term >= body - BODY_DROP_DB)[0]
    if len(reached) == 0:
        detail["reason"] = "no part reaches the body level"
        return result
    body_start, body_end = reached[0] * FEATURE_HOP, (reached[-1] + 1) * FEATURE_HOP
    gaps = dropouts(audio, rate)
    limit = min(body_end, avoid_after if avoid_after is not None else math.inf)
    detail.update({"bodyLufs": round(body, 2), "bodyStartSeconds": round(body_start, 2),
                   "bodyEndSeconds": round(body_end, 2), "dropouts": [[round(a, 2), round(b, 2)] for a, b in gaps[:20]],
                   "avoidAfterSeconds": avoid_after, "avoidBreaks": avoid_breaks})
    if avoid_breaks:
        found = breaks(audio, rate, short_term, body, (body_start, body_end))
        passed = [(float(a), float(b), "beat map") for a, b in (avoid_ranges or [])]
        detail["avoided"] = [[round(a, 2), round(b, 2), why] for a, b, why in sorted(found + passed)][:60]
        gaps = gaps + [(a, b) for a, b, _ in found + passed]

    envelope = onset_envelope(mono, rate)
    chroma, spectrum = chroma_and_spectrum(mono, rate)
    periods = bar_periods(envelope, grid_bar)
    deviation_ms = (periods[:, 1] - grid_bar) * 1000
    detail["tempoMap"] = {"gridBarSeconds": round(grid_bar, 6), "barLengthDeviationMs": [
        round(float(deviation_ms.min()), 2), round(float(deviation_ms.max()), 2)],
        "medianBarCorrelation": round(float(np.median(periods[:, 2])), 3)}

    # Beat timeline from the grid beat nearest the body start, following the tempo map. A global
    # grid can sit off the beat here when the tempo drifts, so the phase is fitted locally first:
    # the shift within half a beat whose comb of 16 beats meets the most onset energy.
    offset = beat_offset if beat_offset is not None and math.isfinite(beat_offset) else 0.0
    first = offset + math.ceil((max(body_start, 4 * beat) - offset) / beat) * beat
    local_beat = float(np.interp(first, periods[:, 0], periods[:, 1])) / BEATS_PER_BAR
    pooled = np.maximum.reduce([np.roll(envelope, k) for k in range(-2, 3)])
    shifts = np.arange(-int(local_beat * ENVELOPE_RATE / 2), int(local_beat * ENVELOPE_RATE / 2) + 1)
    comb = np.round((first + np.arange(16) * local_beat) * ENVELOPE_RATE).astype(int)
    usable = [s for s in shifts if comb[0] + s >= 0 and comb[-1] + s < len(pooled)]
    if usable:
        first += usable[int(np.argmax([pooled[comb + s].sum() for s in usable]))] / ENVELOPE_RATE
    detail["anchorSeconds"] = round(first, 4)
    beats = [first]
    while beats[-1] + beat < duration:
        beats.append(beats[-1] + float(np.interp(beats[-1], periods[:, 0], periods[:, 1])) / BEATS_PER_BAR)
    beats = np.array(beats)

    # Downbeat: the beat phase with the most chord change and low-band attack.
    change, attack = np.zeros(BEATS_PER_BAR), np.zeros(BEATS_PER_BAR)
    for index, time in enumerate(beats):
        frame = int(round(time / FEATURE_HOP))
        sample = int(round(time * ENVELOPE_RATE))
        if frame < 10 or frame + 10 > chroma.shape[1] or sample + 30 > len(envelope):
            continue
        change[index % BEATS_PER_BAR] += 1 - cosine(chroma[:, frame - 10:frame].mean(axis=1), chroma[:, frame:frame + 10].mean(axis=1))
        attack[index % BEATS_PER_BAR] += envelope[max(0, sample - 5):sample + 30].max()
    phase = int(np.argmax(change / max(change.max(), 1e-12) + attack / max(attack.max(), 1e-12)))
    bars = beats[phase::BEATS_PER_BAR]
    detail["downbeatPhase"] = phase

    def blocked(start: float, end: float) -> bool:
        return any(a < end and b > start for a, b in gaps)

    def mean_momentary(time: float) -> float:
        return float(np.mean(momentary[int(round((time - 1) / FEATURE_HOP)):int(round((time + 1) / FEATURE_HOP))]))

    span = int(round(2 * BEATS_PER_BAR * beat / FEATURE_HOP / 2))
    margin = half + 0.1
    starts = [i for i, time in enumerate(bars)
              if time >= body_start + margin and time - BEATS_PER_BAR * beat >= 0][:MAX_STARTS]
    rows = []
    window = (int(round(0.5 * ENVELOPE_RATE)), int(round(2.5 * ENVELOPE_RATE)))
    offsets = np.arange(-window[0] - REFINE_MS, window[1] + REFINE_MS) / ENVELOPE_RATE
    sample_index = np.arange(len(envelope))

    def tempo_ratio(start: float, end: float) -> float:
        """Bar length at `end` over bar length at `start` (from the tempo map)."""
        return float(np.interp(end, periods[:, 0], periods[:, 1]) / np.interp(start, periods[:, 0], periods[:, 1]))

    def scaled_segment(end: float, ratio: float, around: np.ndarray = offsets) -> np.ndarray:
        """The envelope around `end` on the start's time scale (pivot at the bar line), so a
        tempo that drifted between the two points does not smear the correlation."""
        return np.interp((end + around * ratio) * ENVELOPE_RATE, sample_index, envelope)

    seam_reach = SEAM_LAG_SEARCH_MS
    seam_offsets = np.arange(-int(half * ENVELOPE_RATE) - seam_reach, int(half * ENVELOPE_RATE) + seam_reach) / ENVELOPE_RATE

    def seam_onset_lag(start: float, end: float, ratio: float) -> int:
        """Where the onsets inside the seam itself line up best, in ms from `end` (0 = the two
        sides' drums coincide while both are heard)."""
        s0 = int(round(start * ENVELOPE_RATE))
        inside = envelope[s0 - int(half * ENVELOPE_RATE):s0 + int(half * ENVELOPE_RATE)]
        return int(np.argmax(shifted_ncc(inside, scaled_segment(end, ratio, seam_offsets)))) - seam_reach
    seam_frames = int(round(SEAM_SECONDS * rate))
    seam_weight = np.sin(np.pi * np.arange(seam_frames) / seam_frames)
    weighted = signal.sosfilt(k_weighting(rate), mono)

    def seam_correlation(start: float, end: float) -> float:
        """Correlation r of the two sides over the seam (K-weighted, weighted by the gains'
        product sin(pi p)). Plain cos/sin gains change the loudness mid-seam by 10 log10(1 + r);
        the engine divides them by sqrt(1 + r sin(pi p)) so it stays flat."""
        a0 = int(round((start - half) * rate))
        c0 = int(round((end - half) * rate))
        x, y = weighted[a0:a0 + seam_frames], weighted[c0:c0 + seam_frames]
        if len(x) < seam_frames or len(y) < seam_frames:
            return -1.0
        xy, xx, yy = np.dot(seam_weight * x, y), np.dot(seam_weight * x, x), np.dot(seam_weight * y, y)
        return float(xy / math.sqrt(xx * yy)) if xx > 0 and yy > 0 else 0.0

    for start_index in starts:
        start = bars[start_index]
        s0 = int(round(start * ENVELOPE_RATE))
        reference = envelope[s0 - window[0]:s0 + window[1]]
        f0 = int(round(start / FEATURE_HOP))
        if len(reference) < sum(window) or f0 - span < 0:
            continue
        start_chroma = chroma[:, f0 - span:f0 + span].mean(axis=1)
        start_spectrum = spectrum[:, f0 - span:f0 + span].mean(axis=1)
        start_level = mean_momentary(start)
        for end_index in range(start_index + MIN_LOOP_BEATS // BEATS_PER_BAR, len(bars)):
            end = bars[end_index]
            if end > limit - margin - REFINE_MS / 1000 or blocked(start - margin, end + margin + REFINE_MS / 1000):
                break
            if (end + (window[1] + REFINE_MS) / ENVELOPE_RATE) * ENVELOPE_RATE >= len(envelope) - 2:
                break
            ratio = tempo_ratio(start, end)
            scores = shifted_ncc(reference, scaled_segment(end, ratio))
            best = int(np.argmax(scores))
            shift = best - REFINE_MS
            refined = end + shift * ratio / ENVELOPE_RATE
            g0 = int(round(refined / FEATURE_HOP))
            if g0 + span > chroma.shape[1]:
                break
            rows.append((start_index, end_index, start, refined, shift, float(scores[best]),
                         cosine(start_chroma, chroma[:, g0 - span:g0 + span].mean(axis=1)),
                         pearson(start_spectrum, spectrum[:, g0 - span:g0 + span].mean(axis=1)),
                         mean_momentary(refined) - start_level, seam_correlation(start, refined),
                         seam_onset_lag(start, refined, ratio)))
    detail["candidates"] = len(rows)
    if not rows:
        detail["reason"] = "body too short for {} beats between bar lines".format(MIN_LOOP_BEATS)
        return result

    table = np.array(rows)
    bars_apart = table[:, 1] - table[:, 0]
    onset = table[:, 5]
    short = bars_apart <= 16
    onset_reference = float(np.percentile(onset[short] if short.any() else onset, 75))
    onset_floor = max(THRESHOLDS["onsetFloor"], THRESHOLDS["onsetRelative"] * onset_reference)
    passing = ((table[:, 6] >= THRESHOLDS["chroma"]) & (table[:, 7] >= THRESHOLDS["spectrum"])
               & (np.abs(table[:, 8]) <= THRESHOLDS["loudnessDb"]) & (onset >= onset_floor)
               & (table[:, 9] >= THRESHOLDS["seamCorrelationFloor"]) & (np.abs(table[:, 10]) <= THRESHOLDS["seamOnsetLagMs"])
               & (np.abs(table[:, 4]) < REFINE_MS - 1))
    detail.update({"onsetReference": round(onset_reference, 3), "onsetFloor": round(onset_floor, 3),
                   "passing": int(passing.sum())})
    if not passing.any():
        best = int(np.argmax(0.4 * np.clip(onset / max(onset_reference, 1e-3), 0, 1) + 0.3 * table[:, 6] + 0.3 * table[:, 7]))
        detail["reason"] = "no seam matches on both sides"
        detail["closest"] = describe(table[best], onset_reference)
        return result
    quality = 0.4 * np.minimum(onset / max(onset_reference, 1e-3), 1.2) / 1.2 + 0.3 * table[:, 6] + 0.3 * table[:, 7]
    lengths = table[:, 3] - table[:, 2]
    # Longest first, then the closest match; whole 4-bar phrases keep fills and chord cycles in place.
    phrase = np.where(bars_apart % 4 == 0, PHRASE_BONUS, 0.0)
    utility = np.where(passing, lengths / lengths[passing].max() + quality + phrase, -np.inf)
    chosen_index = int(np.argmax(utility))
    pick = table[chosen_index]

    # Sub-millisecond: the parabola through the onset correlation peak. (The waveform is not
    # used: its correlation repeats every bass cycle, and its peaks pull the drums apart.)
    start = float(pick[2])
    bar_line = float(bars[int(pick[1])])
    ratio = tempo_ratio(start, bar_line)
    s0 = int(round(start * ENVELOPE_RATE))
    scores = shifted_ncc(envelope[s0 - window[0]:s0 + window[1]], scaled_segment(bar_line, ratio))
    best = int(np.argmax(scores))
    fraction = 0.0
    if 0 < best < len(scores) - 1:
        curvature = scores[best - 1] - 2 * scores[best] + scores[best + 1]
        if curvature < 0:
            fraction = float(np.clip(0.5 * (scores[best - 1] - scores[best + 1]) / curvature, -0.5, 0.5))
    # The reference starts on a whole millisecond; carry the start's rounding over to the end.
    end = bar_line + (best - REFINE_MS + fraction) * ratio / ENVELOPE_RATE + (start - s0 / ENVELOPE_RATE) * ratio

    correlation = min(max(seam_correlation(start, end), SEAM_CORRELATION_RANGE[0]), SEAM_CORRELATION_RANGE[1])
    result.update({"loopStartSeconds": round(start, 6), "loopEndSeconds": round(end, 6),
                   "loopBars": int(pick[1] - pick[0]), "loopSeamCorrelation": round(correlation, 3)})
    chosen = describe(pick, onset_reference)
    chosen.update({"loopEndSeconds": round(end, 6), "refineShiftMs": round((end - bar_line) * 1000, 2),
                   "tempoRatio": round(ratio, 5),
                   "seamCorrelation": round(correlation, 3),
                   "plainCrossfadeLevelDb": round(10 * math.log10(1 + correlation), 2), "quality": round(float(quality[chosen_index]), 3)})
    detail["chosen"] = chosen
    return result


def describe(row: np.ndarray, onset_reference: float) -> Dict[str, Any]:
    return {"loopStartSeconds": round(float(row[2]), 6), "loopEndSeconds": round(float(row[3]), 6),
            "bars": int(row[1] - row[0]), "refineShiftMs": int(row[4]),
            "onsetCorrelation": round(float(row[5]), 3),
            "onsetRelative": round(float(row[5]) / max(onset_reference, 1e-3), 3),
            "chromaCosine": round(float(row[6]), 4), "spectrumCorrelation": round(float(row[7]), 4),
            "loudnessDifferenceDb": round(float(row[8]), 2), "seamCorrelation": round(float(row[9]), 3),
            "seamOnsetLagMs": int(row[10])}


# MARK: - Self-test on a synthetic song with an intro, drifting tempo, 4-bar chords and an ending

def synthetic_song(rate: int = 48000) -> Tuple[np.ndarray, Dict[str, Any]]:
    rng = np.random.default_rng(23)
    start_bpm, end_bpm, bars = 98.0, 99.5, 52
    beats_total = bars * BEATS_PER_BAR
    times = [0.25]
    for index in range(beats_total):
        progress = index / beats_total
        times.append(times[-1] + 60.0 / (start_bpm + (end_bpm - start_bpm) * progress))
    times = np.array(times)
    duration = times[-1] + 4.0
    out = np.zeros(int(duration * rate))
    t = np.arange(int(0.25 * rate)) / rate
    kick = 0.9 * np.sin(2 * np.pi * (55 * t + 60 * (1 - np.exp(-t * 30)) / 30)) * np.exp(-t * 18)
    snare = 0.35 * rng.normal(0, 1, len(t)) * np.exp(-t * 28)
    hat = 0.12 * signal.sosfilt(signal.butter(4, 7000, btype="highpass", fs=rate, output="sos"),
                                rng.normal(0, 1, len(t))) * np.exp(-t * 90)
    chords = [[220.0, 277.18, 329.63], [196.0, 246.94, 293.66], [174.61, 220.0, 261.63], [196.0, 246.94, 311.13]]
    intro_bars, outro_bars = 8, 6
    for index, time in enumerate(times[:-1]):
        bar = index // BEATS_PER_BAR
        # Intro: pads only; ending: everything at -9 dB, fading over its last two bars.
        if bar < intro_bars:
            level = 0.25
        elif bar >= bars - outro_bars:
            level = 0.35 * min(1.0, (bars - bar) / 2)
        else:
            level = 1.0
        at = int(time * rate)
        if bar >= intro_bars and at + len(t) < len(out):
            if index % BEATS_PER_BAR in (0, 2):
                out[at:at + len(t)] += level * kick
            else:
                out[at:at + len(t)] += level * snare
            out[at:at + len(t)] += level * hat
            half_beat = int((times[index + 1] - time) / 2 * rate)
            if at + half_beat + len(t) < len(out):
                out[at + half_beat:at + half_beat + len(t)] += level * hat
        if index % BEATS_PER_BAR == 0:
            length = int((times[min(index + BEATS_PER_BAR, len(times) - 1)] - time) * rate)
            tt = np.arange(length) / rate
            # Like generated audio, a repeated chord does not repeat its waveform phase.
            pad = sum(np.sin(2 * np.pi * f * tt + rng.uniform(0, 2 * np.pi)) for f in chords[bar % 4]) / 3
            pad *= np.minimum(1, tt / 0.05) * np.minimum(1, (length / rate - tt) / 0.05)
            out[at:at + length] += 0.3 * max(level, 0.25 if bar < intro_bars else level) * pad
    stereo = np.stack([out, out], axis=1) * 0.5
    truth = {"barTimes": times[::BEATS_PER_BAR], "introEnd": times[intro_bars * BEATS_PER_BAR],
             "outroStart": times[(bars - outro_bars) * BEATS_PER_BAR],
             "gridBpm": 60.0 * beats_total / (times[-1] - times[0]), "firstBeat": times[0]}
    return stereo, truth


def self_test() -> Dict[str, Any]:
    import tempfile
    rate = 48000
    audio, truth = synthetic_song(rate)
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "song.wav"
        sf.write(str(path), audio, rate, subtype="FLOAT")
        found = analyze_loop(path, truth["gridBpm"], truth["firstBeat"])
    start, end = found["loopStartSeconds"], found["loopEndSeconds"]
    assert start is not None and end is not None, found["detail"].get("reason")
    bars = truth["barTimes"]
    start_bar = int(np.argmin(np.abs(bars - start)))
    end_bar = int(np.argmin(np.abs(bars - end)))
    start_error = (start - bars[start_bar]) * 1000
    end_error = (end - bars[end_bar]) * 1000
    seam_error = end_error - start_error
    checks = {
        "after the intro": bool(start >= truth["introEnd"]),
        "before the ending": bool(end + SEAM_SECONDS / 2 <= truth["outroStart"]),
        "whole 4-bar chord cycles": bool((end_bar - start_bar) % 4 == 0 and end_bar - start_bar == found["loopBars"]),
        "at least 32 beats": bool(found["loopBars"] * BEATS_PER_BAR >= MIN_LOOP_BEATS),
        "seam aligned within 1 ms": bool(abs(seam_error) <= 1.0),
        "start on a bar line (10 ms)": bool(abs(start_error) <= 10.0),
    }
    report = {"loopStartSeconds": start, "loopEndSeconds": end, "loopBars": found["loopBars"],
              "startErrorMs": round(start_error, 3), "endErrorMs": round(end_error, 3),
              "seamErrorMs": round(seam_error, 3), "checks": checks,
              "tempoMap": found["detail"]["tempoMap"], "chosen": found["detail"]["chosen"]}
    failed = [name for name, ok in checks.items() if not ok]
    assert not failed, "self-test failed: {} ({})".format(failed, json.dumps(report))
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("--bpm", type=float)
    parser.add_argument("--offset", type=float, default=0.0)
    parser.add_argument("--avoid-after", type=float)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        print(json.dumps(self_test(), indent=1, default=float))
        return 0
    if args.source is None or args.bpm is None:
        parser.error("source and --bpm are required unless --self-test is given")
    print(json.dumps(analyze_loop(args.source, args.bpm, args.offset, args.avoid_after), indent=1, default=float))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
