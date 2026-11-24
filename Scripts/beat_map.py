#!/usr/bin/env python3
"""Beat map for a track whose tempo drifts: the times of its beats, so the focus pulse can follow.

Example::
    .venv-audio/bin/python Scripts/beat_map.py <audio> --bpm 97.4784 [--grid-offset 0.0857]
    .venv-audio/bin/python Scripts/beat_map.py --self-test

Generated songs speed up or slow down a little as they go (often 1-2 % over a few minutes, and
sometimes in a step where a song was extended), so one global beat grid drifts tens of
milliseconds off the beat. Steps:

1. Onset strength: verify_beat_grid's low-band attack function (35-160 Hz envelope slope, whose
   peaks are the landmarks the global grid is fitted to) plus BROAD_SHARE of
   loop_points.onset_envelope (kick, snare and hat bands), max-pooled to DP_RATE.
2. Dynamic programming (Ellis 2007, "Beat tracking by dynamic programming", J. New Music Res.
   36(1)): the sequence that maximises the onset strength on its points minus
   TIGHTNESS * log(interval / P)^2 per interval, P the expected period. It runs over half-beats
   (beats and off-beats alike), so the path cannot slide from beat to off-beat between sections.
   The first pass expects the fitted BPM; the second the running median tempo of the first
   pass's intervals between sounding points, interpolated across breaks, so a break is crossed
   at the tempo of the music around it.
3. Beat parity: as build_library does for the global grid, the half-beats (even or odd) whose
   low-band landmarks carry more summed weight are the beats; it is checked again after step 4.
4. Timing: the landmarks are assigned to the nearest beat or off-beat (at the measured swing) of
   the map and the beat times fitted to them by robust (Cauchy) penalized least squares; a
   penalty on the second difference of the beat times keeps the tempo smooth. Its scale (tempo
   changes slower than L beats pass) is chosen per track by two-fold cross-validation over
   SMOOTH_CANDIDATES: the smoothest scale within CV_TOLERANCE of the lowest held-out error.
   Where no landmark is near, the DP beats hold the map; outside the music it carries the edge
   tempo to the file's ends (first beat within one interval of 0, last within one of the end).

The gate (GATE) asks that neighbouring intervals change smoothly, the map spans the file, and
strong low-band attacks (landmark weight >= STRONG_WEIGHT) line up with the map's beats or
half-beats: held-out coverage within 30 ms and median distance, clearly better than with the best
single global grid (fitted to the same attacks), and in most 16-beat windows. Each attack is
scored by a map fitted without it. Numbers are acoustic measurements, not a listening test.
"""

import argparse
import json
import math
from pathlib import Path
import sys
import time
from typing import Any, Dict, Optional, Tuple

import numpy as np
from scipy import linalg, ndimage, optimize, signal
import soundfile as sf

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import loop_points  # noqa: E402  onset_envelope, ENVELOPE_RATE
import verify_beat_grid  # noqa: E402  extract_onsets

BEAT_MAP_VERSION = 1
MODULATION_TARGET_HZ = 16.0
DP_RATE = 250                  # DP frames per second (4 ms)
SCORE_SMOOTH_SECONDS = 0.008   # Gaussian sigma on the DP's onset strength
BROAD_SHARE = 0.5              # weight of the multi-band envelope next to the low-band attacks
TIGHTNESS = 400.0              # Ellis's alpha on log(interval / P)^2
LAG_RANGE = (0.70, 1.40)       # DP predecessor search, in expected periods
TEMPO_LIMIT = 0.08             # second-pass period within +-8 % of the fitted one
LOCAL_TEMPO_BEATS = 16         # running median of the first pass's intervals
SUPPORT_SCORE = 1.0            # DP points with at least this onset strength (unit SD) measure tempo
SMOOTH_BEATS = 32.0            # timing fit: cut-off period of tempo changes, in beats (default)
SMOOTH_CANDIDATES = (8, 11, 16, 23, 32, 45, 64)   # chosen per track by cross-validation
CV_TOLERANCE = 0.03            # the smoothest scale within 3 % of the best held-out error
CV_SEED = 20261123
CV_MINIMUM_ATTACKS = 24
ASSIGN_SECONDS = 0.035         # a landmark this close to a beat or off-beat observes it ...
ASSIGN_FRACTION = 0.08         # ... and at most this share of the beat interval away
ROBUST_SECONDS = 0.008         # Cauchy scale of the robust fit
FIT_ITERATIONS = 200
FIT_TOLERANCE_SECONDS = 1e-5
DP_ANCHOR_WEIGHT = 0.05        # weight of a DP beat with strong onset strength (landmark weight ~1)
STRONG_WEIGHT = 0.6            # verify_beat_grid landmark weight counted as a strong attack
ALIGN_SECONDS = 0.030          # lines up: within 30 ms (verify_beat_grid's inlier selection)
TIGHT_SECONDS = 0.015
WINDOW_BEATS = 16              # support windows
WINDOW_MIN_ATTACKS = 4
WINDOW_MIN_COVERAGE = 0.6
GATE = {
    "maximumNeighbourIntervalChange": 0.03,   # |interval[k+1] / interval[k] - 1| anywhere
    "intervalRange": [0.85, 1.15],            # every interval within this x the median
    "minimumStrongAttackCoverage": 0.70,      # weighted share of strong attacks within 30 ms
    "maximumMedianResidualMs": 8.0,           # median |distance| of those within 30 ms (held out; the
                                              #   grid check's window phase limit, as loose drums jitter)
    "minimumCoverageGainOverGrid": 0.10,      # coverage(map) - coverage(best global grid) >= this,
    "maximumMissRatioToGrid": 0.60,           #   or misses(map) <= this x misses(grid) at 30 or 15 ms
    "minimumSupportedWindowFraction": 0.75,   # 16-beat windows with >= 4 strong attacks that line up
}
# Everything that shapes a map, recorded with each cached map (build_library keys its cache on
# the code of this file, verify_beat_grid.py and loop_points.py, which holds all of these).
SETTINGS = {
    "dpRate": DP_RATE, "scoreSmoothSeconds": SCORE_SMOOTH_SECONDS, "broadShare": BROAD_SHARE,
    "tightness": TIGHTNESS, "lagRange": list(LAG_RANGE), "tempoLimit": TEMPO_LIMIT,
    "localTempoBeats": LOCAL_TEMPO_BEATS, "supportScore": SUPPORT_SCORE, "smoothBeats": SMOOTH_BEATS,
    "smoothCandidates": list(SMOOTH_CANDIDATES), "cvTolerance": CV_TOLERANCE, "cvSeed": CV_SEED,
    "cvMinimumAttacks": CV_MINIMUM_ATTACKS, "assignSeconds": ASSIGN_SECONDS, "assignFraction": ASSIGN_FRACTION,
    "robustSeconds": ROBUST_SECONDS, "fitIterations": FIT_ITERATIONS, "fitToleranceSeconds": FIT_TOLERANCE_SECONDS,
    "dpAnchorWeight": DP_ANCHOR_WEIGHT, "strongWeight": STRONG_WEIGHT, "alignSeconds": ALIGN_SECONDS,
    "tightSeconds": TIGHT_SECONDS, "windowBeats": WINDOW_BEATS, "windowMinimumAttacks": WINDOW_MIN_ATTACKS,
    "windowMinimumCoverage": WINDOW_MIN_COVERAGE, "gate": GATE,
    "landmarkCriteria": verify_beat_grid.CRITERIA, "loopEnvelopeVersion": loop_points.LOOP_VERSION,
}


# MARK: - Onset strength and dynamic programming

def _pooled(values: np.ndarray, rate: int) -> np.ndarray:
    """Max-pooled to DP_RATE, Gaussian smoothed, unit standard deviation."""
    pool = rate // DP_RATE
    frames = len(values) // pool
    pooled = values[:frames * pool].reshape(frames, pool).max(axis=1)
    smooth = ndimage.gaussian_filter1d(pooled, SCORE_SMOOTH_SECONDS * DP_RATE)
    deviation = float(np.std(smooth))
    return smooth / deviation if deviation > 0 else smooth


def low_band_rising(mono: np.ndarray, rate: int) -> np.ndarray:
    """verify_beat_grid's attack function (35-160 Hz Hilbert envelope, positive slope) at 2 kHz:
    its peaks are the landmarks the global grid is fitted to."""
    analysis = verify_beat_grid.ANALYSIS_RATE
    common = math.gcd(rate, analysis)
    reduced = signal.resample_poly(mono, analysis // common, rate // common)
    low = signal.sosfiltfilt(signal.butter(4, [35.0, 160.0], btype="bandpass", fs=analysis, output="sos"), reduced)
    smooth = ndimage.gaussian_filter1d(np.abs(signal.hilbert(low)), sigma=0.005 * analysis)
    rising = np.maximum(np.gradient(smooth) * analysis, 0.0)
    return ndimage.gaussian_filter1d(rising, sigma=0.002 * analysis)


def onset_strength(mono: np.ndarray, rate: int) -> np.ndarray:
    """The DP's score per DP frame: the low-band attack function plus BROAD_SHARE of
    loop_points' multi-band onset envelope (snare and hats carry the beat where the kick rests)."""
    low = _pooled(low_band_rising(mono, rate), verify_beat_grid.ANALYSIS_RATE)
    if BROAD_SHARE <= 0:
        return low
    broad = _pooled(loop_points.onset_envelope(mono, rate), loop_points.ENVELOPE_RATE)
    count = min(len(low), len(broad))
    return low[:count] + BROAD_SHARE * broad[:count]


def dp_beats(score: np.ndarray, period: np.ndarray, tightness: float = TIGHTNESS) -> np.ndarray:
    """Ellis's dynamic programme; `period` is the expected beat period (frames) at every frame.
    Returns beat frames (increasing), backtracked from the best frame in the last period."""
    count = len(score)
    lags = np.arange(max(1, int(math.floor(LAG_RANGE[0] * period.min()))),
                     int(math.ceil(LAG_RANGE[1] * period.max())) + 1)
    step = int(lags[0])
    cumulative = score.astype(np.float64).copy()
    back = np.full(count, -1, dtype=np.int64)
    log_lags = np.log(lags)[None, :]
    log_period = np.log(period)
    # Frames in [start, start + step) only reach back before `start`: one vector step per block.
    for start in range(step, count, step):
        frames = np.arange(start, min(count, start + step))
        previous = frames[:, None] - lags[None, :]
        valid = previous >= 0
        candidates = np.where(valid, cumulative[np.maximum(previous, 0)], -np.inf) \
            - tightness * (log_lags - log_period[frames][:, None]) ** 2
        best = np.argmax(candidates, axis=1)
        rows = np.arange(len(frames))
        cumulative[frames] = score[frames] + candidates[rows, best]
        back[frames] = previous[rows, best]
    tail = max(1, int(round(period[-1])))
    position = count - tail + int(np.argmax(cumulative[count - tail:]))
    path = [position]
    while back[path[-1]] >= 0:
        path.append(int(back[path[-1]]))
    return np.array(path[::-1], dtype=np.float64)


def local_period(path: np.ndarray, score: np.ndarray, fitted: float, width: int) -> np.ndarray:
    """Expected period per frame from a DP path: the running median (then mean) of `width`
    intervals whose two ends carry onset strength (score >= SUPPORT_SCORE), interpolated in time
    across the rest. Where nothing sounds the DP only coasts at its prior, so those intervals
    say nothing about the tempo; a break is crossed at the tempo of the music on both sides."""
    count = len(score)
    intervals = np.diff(path)
    loud = score[np.clip(path.astype(int), 0, count - 1)] >= SUPPORT_SCORE
    measured = loud[:-1] & loud[1:]
    if measured.sum() < width:
        return np.full(count, fitted)
    median = ndimage.median_filter(intervals[measured], size=width, mode="nearest")
    smooth = ndimage.uniform_filter1d(median, width, mode="nearest")
    curve = np.interp(np.arange(count), (path[:-1] + intervals / 2)[measured], smooth)
    return np.clip(curve, fitted * (1 - TEMPO_LIMIT), fitted * (1 + TEMPO_LIMIT))


# MARK: - Timing fit

def nearest_target(times: np.ndarray, beats: np.ndarray, swing: float) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """For each time: interval k, the fraction a of the nearest target in it (0 = beat k, swing =
    off-beat, 1 = beat k+1) and the signed distance (s). The edge intervals extend outward."""
    k = np.clip(np.searchsorted(beats, times, side="right") - 1, 0, len(beats) - 2)
    start, length = beats[k], beats[k + 1] - beats[k]
    targets = np.array([0.0, swing, 1.0])
    predicted = start[:, None] + targets[None, :] * length[:, None]
    nearest = np.argmin(np.abs(times[:, None] - predicted), axis=1)
    return k, targets[nearest], times - predicted[np.arange(len(times)), nearest]


def second_difference_bands(count: int, lam: float) -> np.ndarray:
    """lam * D2^T D2 in solveh_banded's upper form (row 2 diagonal, 1 first and 0 second super)."""
    bands = np.zeros((3, count))
    j = np.arange(1, count - 1)
    for p, q, value in ((j - 1, j - 1, 1.0), (j, j, 4.0), (j + 1, j + 1, 1.0),
                        (j - 1, j, -2.0), (j, j + 1, -2.0), (j - 1, j + 1, 1.0)):
        np.add.at(bands, (2 - (q - p), q), lam * value)
    return bands


def fit_beats(initial: np.ndarray, times: np.ndarray, weights: np.ndarray, swing: float,
              anchor: np.ndarray, smooth_beats: float = SMOOTH_BEATS,
              iterations: int = FIT_ITERATIONS) -> Tuple[np.ndarray, Dict[str, Any]]:
    """Robust penalized least squares for the beat times (see the module docstring). The
    smoothing weight is set once, from the first assignment's observation weight per beat."""
    beats = initial.astype(np.float64).copy()
    count = len(beats)
    info: Dict[str, Any] = {"observations": 0, "iterations": 0}
    if count < 4:
        return beats, info
    lam = None
    for iteration in range(iterations):
        k, fraction, distance = nearest_target(times, beats, swing)
        interval = np.diff(beats)[k]
        inside = (times >= beats[0] - 0.5 * interval) & (times <= beats[-1] + 0.5 * interval)
        keep = inside & (np.abs(distance) <= np.minimum(ASSIGN_SECONDS, ASSIGN_FRACTION * interval))
        omega = weights[keep] / (1.0 + (distance[keep] / ROBUST_SECONDS) ** 2)
        kk, a, observed = k[keep], fraction[keep], times[keep]
        on_left = a < 0.5 * swing          # beat k
        on_right = a > 0.5 * (1 + swing)   # beat k+1
        off = ~(on_left | on_right)        # off-beat between them: (1 - swing) b_k + swing b_{k+1}
        if lam is None:
            per_beat = max(float(weights[keep].sum() + anchor.sum()) / count, 1e-9)
            lam = per_beat * (smooth_beats / (2 * math.pi)) ** 4
        bands = second_difference_bands(count, lam)
        rhs = np.zeros(count)
        bands[2] += anchor
        rhs += anchor * initial
        for index, mask in ((kk, on_left), (kk + 1, on_right)):
            np.add.at(bands[2], index[mask], omega[mask])
            np.add.at(rhs, index[mask], omega[mask] * observed[mask])
        cl, cr = 1.0 - swing, swing
        np.add.at(bands[2], kk[off], omega[off] * cl * cl)
        np.add.at(bands[2], kk[off] + 1, omega[off] * cr * cr)
        np.add.at(bands[1], kk[off] + 1, omega[off] * cl * cr)
        np.add.at(rhs, kk[off], omega[off] * cl * observed[off])
        np.add.at(rhs, kk[off] + 1, omega[off] * cr * observed[off])
        updated = linalg.solveh_banded(bands, rhs, lower=False)
        change = float(np.max(np.abs(updated - beats)))
        beats = updated
        info = {"observations": int(keep.sum()), "iterations": iteration + 1, "lambda": round(lam, 3),
                "lastChangeMs": round(change * 1000, 4)}
        if change < FIT_TOLERANCE_SECONDS:
            break
    return beats, info


def estimate_swing(times: np.ndarray, weights: np.ndarray, beats: np.ndarray) -> float:
    """Weighted median position of strong off-beat landmarks within their interval (0.5 straight)."""
    k, fraction, _ = nearest_target(times, beats, 0.5)
    position = (times - beats[k]) / (beats[k + 1] - beats[k])
    middle = (position > 0.3) & (position < 0.7) & (weights >= STRONG_WEIGHT)
    if middle.sum() < 8:
        return 0.5
    return float(np.clip(verify_beat_grid.weighted_median(position[middle], weights[middle]), 0.4, 0.7))


def parity_weights(times: np.ndarray, weights: np.ndarray, beats: np.ndarray, swing: float) -> Tuple[float, float]:
    """Summed landmark weight within ALIGN_SECONDS of the beats and of the off-beats."""
    _, fraction, distance = nearest_target(times, beats, swing)
    near = np.abs(distance) <= ALIGN_SECONDS
    off = near & (fraction == swing)
    return float(weights[near & ~off].sum()), float(weights[off].sum())


def extend_to_file(beats: np.ndarray, duration: float, edge_beats: int = 8) -> np.ndarray:
    """Beats inside [0, duration], extended with the mean interval of the edge beats so that the
    first beat is within one interval of 0 and the last within one interval of the end."""
    beats = beats[(beats >= 0) & (beats <= duration)]
    first = float(np.mean(np.diff(beats[:edge_beats + 1])))
    last = float(np.mean(np.diff(beats[-edge_beats - 1:])))
    head = beats[0] - first * np.arange(1, int(beats[0] // first) + 1)[::-1]
    tail = beats[-1] + last * np.arange(1, int((duration - beats[-1]) // last) + 1)
    return np.concatenate([head, beats, tail])


# MARK: - Alignment measures and the best global grid

def map_distance(times: np.ndarray, beats: np.ndarray) -> np.ndarray:
    """Signed distance (s) from each time to the nearest beat or half-beat of the map."""
    return nearest_target(times, beats, 0.5)[2]


def map_distance_to(times: np.ndarray, points: np.ndarray) -> np.ndarray:
    """Signed distance (s) from each time to the nearest of `points` (increasing)."""
    k = np.clip(np.searchsorted(points, times), 1, len(points) - 1)
    left, right = times - points[k - 1], times - points[k]
    return np.where(np.abs(left) <= np.abs(right), left, right)


def grid_distance(times: np.ndarray, anchor: float, half: float) -> np.ndarray:
    return (times - anchor + half / 2) % half - half / 2


def alignment(distance: np.ndarray, weights: np.ndarray) -> Dict[str, Optional[float]]:
    near = np.abs(distance) <= ALIGN_SECONDS
    total = float(weights.sum())
    inliers = np.abs(distance[near]) * 1000
    return {"coverage30ms": float(weights[near].sum() / total) if total else None,
            "coverage15ms": float(weights[np.abs(distance) <= TIGHT_SECONDS].sum() / total) if total else None,
            "medianResidualMs": float(np.median(inliers)) if len(inliers) else None,
            "p95ResidualMs": float(np.percentile(inliers, 95)) if len(inliers) else None}


def best_global_grid(times: np.ndarray, weights: np.ndarray, beat: float) -> Tuple[float, float]:
    """(anchor, half-beat period) of the single grid that best fits the strong attacks: a tempo
    scan (+-3 %) on phase concentration, then the smooth coverage score sum w exp(-d^2/2s^2)
    (s = 15 ms) maximised from the best scan points."""
    half0 = beat / 2

    def score(x: np.ndarray) -> float:
        d = grid_distance(times, x[0], x[1])
        return -float(np.sum(weights * np.exp(-0.5 * (d / TIGHT_SECONDS) ** 2)))

    rel = np.arange(-0.03, 0.03 + 1e-12, 5e-5)
    concentration = np.empty(len(rel))
    phase = np.empty(len(rel))
    for first in range(0, len(rel), 64):
        periods = half0 * (1 + rel[first:first + 64])
        z = np.sum(weights[None, :] * np.exp(2j * np.pi * times[None, :] / periods[:, None]), axis=1)
        concentration[first:first + 64] = np.abs(z)
        phase[first:first + 64] = (np.angle(z) / (2 * np.pi) * periods) % periods
    best = None
    for index in np.argsort(concentration)[::-1][:5]:
        start = np.array([phase[index], half0 * (1 + rel[index])])
        found = optimize.minimize(score, start, method="Nelder-Mead",
                                  options={"xatol": 1e-7, "fatol": 1e-9, "initial_simplex":
                                           [start, start + [0.004, 0], start + [0, half0 * 2e-4]]})
        if best is None or found.fun < best.fun:
            best = found
    return float(best.x[0] % best.x[1]), float(best.x[1])


# MARK: - Smoothing scale by cross-validation

def choose_smoothing(initial: np.ndarray, times: np.ndarray, weights: np.ndarray, swing: float,
                     anchor: np.ndarray) -> Tuple[float, Dict[str, float], np.ndarray]:
    """Two-fold cross-validation over SMOOTH_CANDIDATES: fit on a random half of the landmarks,
    score the other half's strong attacks by their RMS distance (capped at 30 ms) to the map's
    beats or half-beats. The smoothest scale within CV_TOLERANCE of the best error is chosen.
    Returns it, the error per scale (ms), and every strong attack's held-out distance at it (s;
    NaN for the other landmarks): each strong attack is scored by a map fitted without it."""
    strong = weights >= STRONG_WEIGHT
    if strong.sum() < CV_MINIMUM_ATTACKS:
        return SMOOTH_BEATS, {}, np.full(len(times), np.nan)
    folds = np.random.default_rng(CV_SEED).integers(0, 2, len(times))
    table: Dict[str, float] = {}
    held: Dict[float, np.ndarray] = {}
    for scale in SMOOTH_CANDIDATES:
        distance = np.full(len(times), np.nan)
        for fold in (0, 1):
            train = folds == fold
            fitted, _ = fit_beats(initial, times[train], weights[train] ** 2, swing, anchor, scale)
            test = ~train & strong
            distance[test] = map_distance(times[test], fitted)
        d, w = distance[strong], weights[strong]
        table[str(scale)] = float(np.sqrt(np.sum(w * np.minimum(np.abs(d), ALIGN_SECONDS) ** 2) / w.sum()) * 1000)
        held[scale] = distance
    best = min(table.values())
    chosen = max(scale for scale in SMOOTH_CANDIDATES if table[str(scale)] <= best * (1 + CV_TOLERANCE))
    return chosen, {key: round(value, 3) for key, value in table.items()}, held[chosen]


# MARK: - Analysis

def _rounded(values: Dict[str, Optional[float]], digits: int = 4) -> Dict[str, Optional[float]]:
    return {key: None if value is None else round(value, digits) for key, value in values.items()}


def beat_map_for(mono: np.ndarray, rate: int, bpm: float, grid_offset: Optional[float] = None) -> Dict[str, Any]:
    """Beat map of mono audio. `bpm` is the fitted global tempo (the DP's prior); `grid_offset`,
    when given, is the global grid's beatOffsetSeconds, used only to report the agreement."""
    started = time.time()
    duration = len(mono) / rate
    beat = 60.0 / bpm
    score = onset_strength(mono, rate)
    landmark_times, landmark_weights, _ = verify_beat_grid.extract_onsets(mono, rate)
    if len(landmark_times) < CV_MINIMUM_ATTACKS:
        return {"version": BEAT_MAP_VERSION, "accepted": False, "failures": ["Too few low-band attacks to follow."],
                "quality": {"landmarks": len(landmark_times)}, "gridAgreement": None,
                "detail": {"gate": GATE, "seconds": round(time.time() - started, 2)}}

    # Two DP passes over half-beats (beats and off-beats alike, so the path cannot slide from one
    # to the other between sections): fitted tempo, then the local tempo of the first pass.
    fitted = beat / 2 * DP_RATE
    first_pass = dp_beats(score, np.full(len(score), fitted))
    second_pass = dp_beats(score, local_period(first_pass, score, fitted, 2 * LOCAL_TEMPO_BEATS))
    points = second_pass / DP_RATE
    near = [float(landmark_weights[np.abs(map_distance_to(landmark_times, points[p::2])) <= ALIGN_SECONDS].sum())
            for p in (0, 1)]
    dp_parity = int(near[1] > near[0])
    chosen = second_pass[dp_parity::2]
    dp = chosen / DP_RATE

    # Timing fit on the low-band landmarks; the DP beats hold the map where none are near.
    weights = landmark_weights ** 2
    strength = score[np.clip(chosen.astype(int), 0, len(score) - 1)]
    anchor = DP_ANCHOR_WEIGHT * np.clip(strength / max(float(np.percentile(score, 99)), 1e-9), 0, 1) + 1e-6
    swing = estimate_swing(landmark_times, landmark_weights, dp)
    smooth, cv_table, held_all = choose_smoothing(dp, landmark_times, landmark_weights, swing, anchor)
    beats, fit = fit_beats(dp, landmark_times, weights, swing, anchor, smooth)
    on, off = parity_weights(landmark_times, landmark_weights, beats, swing)
    parity = {"rule": "the parity (beat or off-beat) with the larger summed landmark weight within 30 ms is the beat",
              "dpHalfBeatWeights": [round(near[0], 3), round(near[1], 3)], "dpParity": dp_parity,
              "beatWeight": round(on, 3), "offBeatWeight": round(off, 3), "shifted": bool(off > on)}
    if off > on:
        # The off-beats become the beats; the old beats now sit at 1 - swing of each interval.
        shifted = beats[:-1] + swing * np.diff(beats)
        anchor = np.interp(shifted, beats, anchor)
        swing = 1.0 - swing
        beats, fit = fit_beats(shifted, landmark_times, weights, swing, anchor, smooth)
    # The catalog keeps milliseconds; everything below (c, the nominal rate, the quality) is
    # measured on exactly those times.
    beats = np.round(extend_to_file(beats, duration), 3)
    if beats[-1] > duration:
        beats[-1] -= 0.001

    # Quality: in-sample and held-out alignment of strong attacks, the best single global grid,
    # 16-beat windows, interval smoothness.
    intervals = np.diff(beats)
    median_interval = float(np.median(intervals))
    neighbour = np.abs(intervals[1:] / intervals[:-1] - 1)
    strong = landmark_weights >= STRONG_WEIGHT
    times_s, weights_s = landmark_times[strong], landmark_weights[strong]
    on_map = alignment(map_distance(times_s, beats), weights_s)
    held_distance = held_all[strong]
    cross_validated = bool(np.all(np.isfinite(held_distance)))
    if not cross_validated:  # too few strong attacks to hold any out: score the map in-sample
        held_distance = map_distance(times_s, beats)
    held_out = alignment(held_distance, weights_s)
    anchor_g, half_g = best_global_grid(times_s, weights_s, beat)
    on_grid = alignment(grid_distance(times_s, anchor_g, half_g), weights_s)
    windows, scorable, supported = [], 0, 0
    for first in range(0, len(beats) - 1, WINDOW_BEATS):
        last = min(first + WINDOW_BEATS, len(beats) - 1)
        inside = (times_s >= beats[first]) & (times_s < beats[last])
        count = int(inside.sum())
        coverage = float(weights_s[inside & (np.abs(held_distance) <= ALIGN_SECONDS)].sum()
                         / weights_s[inside].sum()) if count else None
        if count >= WINDOW_MIN_ATTACKS:
            scorable += 1
            supported += int(coverage >= WINDOW_MIN_COVERAGE)
        windows.append([round(float(beats[first]), 2), count, None if coverage is None else round(coverage, 3)])

    def misses(values: Dict[str, Optional[float]], key: str) -> float:
        return 1.0 - (values[key] or 0.0)

    ratios = {key: (misses(held_out, key) / misses(on_grid, key) if misses(on_grid, key) > 0 else None)
              for key in ("coverage30ms", "coverage15ms")}
    gain = (held_out["coverage30ms"] or 0.0) - (on_grid["coverage30ms"] or 0.0)
    better = gain >= GATE["minimumCoverageGainOverGrid"] or any(
        ratio is not None and ratio <= GATE["maximumMissRatioToGrid"] for ratio in ratios.values())
    quality = {
        "beats": len(beats), "medianIntervalSeconds": round(median_interval, 6),
        "firstBeatSeconds": round(float(beats[0]), 4), "lastBeatSeconds": round(float(beats[-1]), 4),
        "durationSeconds": round(duration, 3),
        "maximumNeighbourIntervalChange": round(float(neighbour.max()), 5) if len(neighbour) else None,
        "p99NeighbourIntervalChange": round(float(np.percentile(neighbour, 99)), 5) if len(neighbour) else None,
        "intervalRange": [round(float(intervals.min() / median_interval), 4), round(float(intervals.max() / median_interval), 4)],
        "tempoRangeBpm": [round(60 / float(intervals.max()), 3), round(60 / float(intervals.min()), 3)],
        "smoothingBeats": smooth, "crossValidationErrorMs": cv_table, "crossValidated": cross_validated,
        "strongAttacks": int(strong.sum()), "strongAttackWeightThreshold": STRONG_WEIGHT,
        "heldOut": _rounded(held_out), "map": _rounded(on_map),
        "bestGlobalGrid": dict(_rounded(on_grid), bpm=round(30.0 / half_g, 4), anchorSeconds=round(anchor_g, 4)),
        "coverageGainOverGrid": round(gain, 4),
        "missRatioToGrid": {key: None if value is None else round(value, 4) for key, value in ratios.items()},
        "scorableWindows": scorable, "supportedWindows": supported,
        "supportedWindowFraction": round(supported / scorable, 4) if scorable else None,
        "swing": round(swing, 4),
    }
    checks = [
        (bool(np.all(intervals > 0)), "Beat times are not strictly increasing."),
        (0 <= beats[0] < intervals[0] and duration - intervals[-1] < beats[-1] <= duration,
         "The map does not reach both ends of the file."),
        (quality["maximumNeighbourIntervalChange"] is not None
         and quality["maximumNeighbourIntervalChange"] <= GATE["maximumNeighbourIntervalChange"],
         "Neighbouring beat intervals change too abruptly."),
        (GATE["intervalRange"][0] <= quality["intervalRange"][0] and quality["intervalRange"][1] <= GATE["intervalRange"][1],
         "Some beat intervals are far from the median."),
        ((held_out["coverage30ms"] or 0) >= GATE["minimumStrongAttackCoverage"],
         "Too few strong attacks line up with the map."),
        (held_out["medianResidualMs"] is not None and held_out["medianResidualMs"] <= GATE["maximumMedianResidualMs"],
         "Median attack-to-map error is too large."),
        (better, "The map is not clearly better than the best single global grid."),
        (scorable > 0 and supported / scorable >= GATE["minimumSupportedWindowFraction"],
         "Too many stretches of the music do not line up with the map."),
    ]
    failures = [reason for passed, reason in checks if not passed]
    cycles = max(1, int(round(MODULATION_TARGET_HZ * median_interval)))
    agreement = None
    if grid_offset is not None and math.isfinite(grid_offset) and strong.any():
        inside = (beats >= times_s.min()) & (beats <= times_s.max())
        to_grid = (beats[inside] - grid_offset + beat / 2) % beat - beat / 2
        agreement = {"gridBeatOffsetSeconds": grid_offset, "gridBpm": bpm, "beatsCompared": int(inside.sum()),
                     "medianAbsoluteDifferenceMs": round(float(np.median(np.abs(to_grid))) * 1000, 3),
                     "p95AbsoluteDifferenceMs": round(float(np.percentile(np.abs(to_grid), 95)) * 1000, 3),
                     "medianSignedDifferenceMs": round(float(np.median(to_grid)) * 1000, 3)}
    return {
        "version": BEAT_MAP_VERSION, "accepted": not failures, "failures": failures,
        "beatTimes": [float(b) for b in beats],
        "pulseCyclesPerBeat": cycles, "modulationHz": round(cycles / median_interval, 4),
        "beatOffsetSeconds": float(beats[0]),
        "quality": quality, "gridAgreement": agreement,
        "detail": {"gate": GATE, "parity": parity, "fit": fit, "dpBeats": len(dp),
                   "landmarks": len(landmark_times), "windows": windows,
                   "seconds": round(time.time() - started, 2)},
    }


def analyze_beats(path: Path, bpm: float, grid_offset: Optional[float] = None) -> Dict[str, Any]:
    """beat_map_for on an audio file (channels averaged)."""
    audio, rate = sf.read(str(path), dtype="float32", always_2d=True)
    if not np.isfinite(audio).all() or len(audio) < rate:
        raise ValueError("audio must be finite and at least one second long")
    mono = audio.mean(axis=1, dtype=np.float64)
    del audio
    return beat_map_for(mono, rate, bpm, grid_offset)


# MARK: - Self-test on synthetic drums with a drifting tempo

def _synthetic(rate: int, beat_times: np.ndarray, duration: float, drums: np.ndarray, seed: int,
               syncopated: bool = True) -> np.ndarray:
    """Kick on beats 1 and 3 (and the "and" of 3), snare on 2 and 4, hats on every eighth, each
    hit with 2 ms jitter and +-20 % level; pads and noise throughout. `drums` masks beats."""
    rng = np.random.default_rng(seed)
    out = rng.normal(0, 0.002, int(duration * rate))
    t = np.arange(int(0.25 * rate)) / rate
    kick = 0.8 * np.sin(2 * np.pi * (55 * t + 60 * (1 - np.exp(-t * 30)) / 30)) * np.exp(-t * 18)
    snare = 0.3 * rng.normal(0, 1, len(t)) * np.exp(-t * 28)
    hat = 0.1 * signal.sosfilt(signal.butter(4, 7000, btype="highpass", fs=rate, output="sos"),
                               rng.normal(0, 1, len(t))) * np.exp(-t * 90)

    def hit(sound: np.ndarray, when: float) -> None:
        start = int(round((when + rng.normal(0, 0.002)) * rate))
        if 0 <= start and start + len(sound) < len(out):
            out[start:start + len(sound)] += rng.uniform(0.8, 1.2) * sound

    for index, when in enumerate(beat_times[:-1]):
        if not drums[index]:
            continue
        half = when + (beat_times[index + 1] - when) / 2
        position = index % 4
        hit(kick if position in (0, 2) else snare, when)
        hit(hat, when)
        hit(hat, half)
        if syncopated and position == 2:
            hit(0.7 * kick, half)
    time_axis = np.arange(len(out)) / rate
    pads = sum(np.sin(2 * np.pi * f * time_axis + rng.uniform(0, 2 * np.pi)) for f in (220.0, 277.18, 329.63))
    return out + 0.04 * pads


def _beats_from_tempo(bpm_at, start: float, end: float) -> np.ndarray:
    times = [start]
    while times[-1] < end:
        times.append(times[-1] + 60.0 / bpm_at(times[-1]))
    return np.array(times)


def self_test() -> Dict[str, Any]:
    rate = 22050
    report: Dict[str, Any] = {}
    checks: Dict[str, bool] = {}

    # 1. Drift: 96 -> 98 BPM over 70 s, a step to 95.5 BPM (an extended song), +-0.3 % wobble,
    #    and a 12 s break with pads only.
    duration = 140.0

    def drifting(t: float) -> float:
        if t < 70:
            return 96.0 + 2.0 * t / 70
        return 95.5 * (1 + 0.003 * math.sin(2 * math.pi * (t - 70) / 23))

    truth = _beats_from_tempo(drifting, 1.37, duration - 1)
    drums = ~((truth >= 80) & (truth < 92))
    audio = _synthetic(rate, truth, duration, drums, seed=11)
    found = beat_map_for(audio, rate, 96.7)
    beats = np.array(found["beatTimes"])
    playing = drums & (truth > 2) & (truth < duration - 3)
    error = map_distance_to(truth[playing], beats) * 1000
    offset = float(np.median(error))
    spread = np.abs(error - offset)
    times, weights, _ = verify_beat_grid.extract_onsets(audio, rate)
    global_fit = verify_beat_grid.fit_grid(times, weights, duration)
    report["drift"] = {"accepted": found["accepted"], "failures": found["failures"],
                       "medianSignedErrorMs": round(offset, 3), "medianSpreadMs": round(float(np.median(spread)), 3),
                       "p95SpreadMs": round(float(np.percentile(spread, 95)), 3),
                       "maxAbsoluteErrorMs": round(float(np.max(np.abs(error))), 3),
                       "pulseCyclesPerBeat": found["pulseCyclesPerBeat"], "quality": found["quality"],
                       "globalGridAccepted": global_fit["accepted"], "globalGridFailures": global_fit["failures"]}
    checks["drifting song accepted"] = found["accepted"]
    checks["fixture really drifts (global grid refused)"] = not global_fit["accepted"]
    checks["on the beat, not the off-beat (|median error| <= 8 ms)"] = abs(offset) <= 8.0
    checks["follows the drift (median spread <= 2 ms, p95 <= 8 ms)"] = bool(
        np.median(spread) <= 2.0 and np.percentile(spread, 95) <= 8.0)
    checks["c = round(16 Hz x median interval) = 10"] = found["pulseCyclesPerBeat"] == 10
    checks["spans the file"] = bool(0 <= beats[0] < beats[1] - beats[0]
                                    and duration - (beats[-1] - beats[-2]) < beats[-1] <= duration)

    # 2. Steady 120 BPM: the map is the grid.
    duration = 60.0
    truth = _beats_from_tempo(lambda t: 120.0, 0.211, duration - 1)
    audio = _synthetic(rate, truth, duration, np.ones(len(truth), bool), seed=12, syncopated=False)
    times, weights, _ = verify_beat_grid.extract_onsets(audio, rate)
    grid = verify_beat_grid.fit_grid(times, weights, duration)
    found = beat_map_for(audio, rate, grid["fittedBpm"], grid["risingAttackGridAnchorSeconds"])
    beats = np.array(found["beatTimes"])
    error = map_distance_to(truth[(truth > 2) & (truth < duration - 3)], beats) * 1000
    report["steady"] = {"accepted": found["accepted"], "failures": found["failures"],
                        "gridAccepted": grid["accepted"], "gridAgreement": found["gridAgreement"],
                        "medianAbsoluteErrorMs": round(float(np.median(np.abs(error))), 3)}
    agreement = found["gridAgreement"] or {}
    checks["steady song: map agrees with the global grid (median <= 2 ms)"] = bool(
        grid["accepted"] and agreement.get("medianAbsoluteDifferenceMs", 99) <= 2.0)

    # 3. No beat: pads and low thumps at random times. The gate must refuse.
    rng = np.random.default_rng(13)
    random_times = np.sort(rng.uniform(1, duration - 1, 90))
    audio = _synthetic(rate, random_times, duration, np.ones(len(random_times), bool), seed=14, syncopated=False)
    found = beat_map_for(audio, rate, 100.0)
    report["noBeat"] = {"accepted": found["accepted"], "failures": found["failures"]}
    checks["random hits refused"] = not found["accepted"]

    failed = [name for name, passed in checks.items() if not passed]
    report["checks"] = checks
    assert not failed, "self-test failed: {} ({})".format(failed, json.dumps(report, default=float))
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("--bpm", type=float)
    parser.add_argument("--grid-offset", type=float)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        print(json.dumps(self_test(), indent=1, default=float))
        return 0
    if args.source is None or args.bpm is None:
        parser.error("source and --bpm are required unless --self-test is given")
    result = analyze_beats(args.source, args.bpm, args.grid_offset)
    if args.report:
        args.report.write_text(json.dumps(result, indent=1) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key not in ("beatTimes", "detail")}, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
