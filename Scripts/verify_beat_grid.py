#!/usr/bin/env python3
"""Estimate an acoustic low-frequency onset grid; never infer clinical efficacy.

This detector does not recognize musical meter or prove where a perceptual
downbeat falls. A kick-like rising-energy landmark has a timbre-dependent delay
from an annotated note onset. Half/double-time interpretations remain possible.
Thresholds below are conservative engineering criteria for exploratory 16-Hz
audio comparisons, not thresholds validated by a clinical study.

Examples::
    .venv-audio/bin/python Scripts/verify_beat_grid.py input.wav \
        --report Verification/beat-grid-original.json
    .venv-audio/bin/python Scripts/verify_beat_grid.py --self-test \
        --report Verification/beat-grid-self-tests.json

No source file is modified. Tempo correction/AM rendering is a separate step,
allowed only after the report's explicit acceptance criteria are satisfied.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
from typing import Any, Dict, Tuple

import numpy as np
from scipy import ndimage, optimize, signal
import soundfile as sf

ANALYSIS_RATE = 2000
CRITERIA = {
    "minimumDurationSeconds": 25.0,
    "minimumOnsets": 30,
    "minimumWeightedPhaseConcentration": 0.55,
    "dominantGridInlierSelectionMs": 30.0,
    "minimumWeightedOnsetCoverageWithin30ms": 0.70,
    "maximumDominantGridMedianAbsoluteResidualMs": 5.0,
    "maximumDominantGridP95AbsoluteResidualMs": 12.0,
    "maximumWindowMedianPhaseDeviationMs": 8.0,
    "minimumScorableDurationFraction": 0.85,
    "windowSeconds": 30.0,
    "maximumTargetTempoErrorBpmAfterPreparation": 0.003,
}


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def weighted_median(values: np.ndarray, weights: np.ndarray) -> float:
    order = np.argsort(values)
    return float(values[order][np.searchsorted(np.cumsum(weights[order]), np.sum(weights) / 2)])


def extract_onsets(mono: np.ndarray, sample_rate: int) -> Tuple[np.ndarray, np.ndarray, Dict[str, Any]]:
    common = math.gcd(sample_rate, ANALYSIS_RATE)
    reduced = signal.resample_poly(mono, ANALYSIS_RATE // common, sample_rate // common)
    sos = signal.butter(4, [35.0, 160.0], btype="bandpass", fs=ANALYSIS_RATE, output="sos")
    low = signal.sosfiltfilt(sos, reduced)
    envelope = np.abs(signal.hilbert(low))
    smooth = ndimage.gaussian_filter1d(envelope, sigma=0.005 * ANALYSIS_RATE)
    # Symmetric smoothing is zero phase; the attack landmark is the rising slope
    # maximum, not the kick waveform's later energy maximum.
    rising = np.maximum(np.gradient(smooth) * ANALYSIS_RATE, 0.0)
    rising = ndimage.gaussian_filter1d(rising, sigma=0.002 * ANALYSIS_RATE)
    reference = float(np.percentile(rising, 99.5))
    if not math.isfinite(reference) or reference <= 1e-10:
        return np.zeros(0), np.zeros(0), {"reason": "No usable low-band attack energy."}
    indices, properties = signal.find_peaks(
        rising, distance=int(0.15 * ANALYSIS_RATE),
        prominence=reference * 0.10, height=reference * 0.15)
    # Sub-sample parabolic interpolation of the independently detected slope.
    times = []
    for index in indices:
        shift = 0.0
        if 0 < index < len(rising) - 1:
            left, center, right = rising[index - 1:index + 2]
            denominator = left - 2 * center + right
            if denominator != 0:
                shift = float(np.clip(0.5 * (left - right) / denominator, -0.5, 0.5))
        times.append((index + shift) / ANALYSIS_RATE)
    heights = properties["peak_heights"]
    scale = float(np.percentile(heights, 80)) if heights.size else 1.0
    weights = np.clip(heights / max(scale, np.finfo(float).tiny), 0.05, 1.5)
    return np.asarray(times), weights, {
        "analysisSampleRateHz": ANALYSIS_RATE,
        "lowBandHz": [35, 160], "bandpassOrder": 4,
        "envelope": "Hilbert magnitude, zero-phase Gaussian 5ms smoothing",
        "landmark": "positive envelope slope peak, Gaussian 2ms smoothing, parabolic timing interpolation",
        "minimumLandmarkSpacingMs": 150,
        "prominenceReferencePercentile": 99.5,
        "referenceSlopeLinearPerSecond": reference,
        "onsetCount": len(times),
        "timingResolutionSeconds": 1 / ANALYSIS_RATE,
        "boundary": "Bass notes, sidechain pumping, fills and timbre changes can be mistaken for kick attacks; no stem separation or human meter annotation.",
    }


def phase_score(times: np.ndarray, weights: np.ndarray, frequency: float) -> float:
    return float(abs(np.sum(weights * np.exp(2j * np.pi * frequency * times))) / np.sum(weights))


def fit_grid(times: np.ndarray, weights: np.ndarray, duration: float,
             minimum_bpm: float = 75.0, maximum_bpm: float = 150.0,
             fixed_bpm: float = None) -> Dict[str, Any]:
    if not (math.isfinite(minimum_bpm) and math.isfinite(maximum_bpm)
            and 30 <= minimum_bpm < maximum_bpm <= 300):
        raise ValueError("Pulse interpretation range must be finite, ordered, and inside 30-300 BPM.")
    if fixed_bpm is not None and (not math.isfinite(fixed_bpm) or fixed_bpm <= 0):
        raise ValueError("Target BPM must be positive and finite.")
    failures = []
    if duration < CRITERIA["minimumDurationSeconds"] or len(times) < CRITERIA["minimumOnsets"]:
        return {"accepted": False, "failures": ["Insufficient duration or detected attack landmarks."],
                "onsetCount": len(times), "durationSeconds": duration}
    step = 1.0 / (duration * 12.0)
    frequencies = np.arange(0.5, max(4.05, maximum_bpm / 30.0 + 0.05), step)
    scores = np.empty(len(frequencies))
    for first in range(0, len(frequencies), 128):
        values = frequencies[first:first + 128]
        scores[first:first + 128] = abs(np.sum(
            np.exp(2j * np.pi * values[:, None] * times) * weights[None, :], axis=1)) / weights.sum()
    peaks, _ = signal.find_peaks(scores, distance=max(1, int(0.015 / step)))
    ranked = peaks[np.argsort(scores[peaks])[::-1]]
    alternatives = []
    for index in ranked[:16]:
        optimized = optimize.minimize_scalar(
            lambda f: -phase_score(times, weights, f),
            bounds=(frequencies[index] - step, frequencies[index] + step),
            method="bounded", options={"xatol": 1e-12})
        alternatives.append({"bpm": float(optimized.x * 60),
                             "weightedPhaseConcentration": float(-optimized.fun)})
    # Low-band attacks can occur on eighth notes as well as quarter notes. Both
    # are compatible with 16Hz at 120BPM (4 or 8 cycles). Rejecting all eighth
    # notes as outliers would confuse syncopation with timing drift. The selected
    # subdivision and the remaining metrical ambiguity are always reported.
    candidates = []
    for alternative in alternatives:
        for subdivision in [1, 2]:
            bpm = alternative["bpm"] / subdivision
            if minimum_bpm <= bpm <= maximum_bpm:
                candidates.append({"bpm": bpm, "subdivision": subdivision,
                                   "weightedPhaseConcentration": alternative["weightedPhaseConcentration"]})
    if not candidates:
        return {"accepted": False, "failures": ["No dominant pulse in the declared interpretation range."],
                "alternativePulseRates": alternatives}
    selected = max(candidates, key=lambda x: x["weightedPhaseConcentration"])
    subdivision = selected["subdivision"]
    frequency = (fixed_bpm if fixed_bpm else selected["bpm"]) * subdivision / 60.0
    period = 1.0 / frequency
    phasor = np.sum(weights * np.exp(2j * np.pi * frequency * times))
    anchor = float((np.angle(phasor) / (2 * np.pi * frequency)) % period)
    for _ in range(6):
        numbers = np.rint((times - anchor) / period)
        residual = times - anchor - numbers * period
        keep = np.abs(residual) <= 0.045
        if np.count_nonzero(keep) < 10:
            break
        numbers_in = numbers[keep]
        times_in = times[keep]
        weights_in = np.sqrt(weights[keep])
        if fixed_bpm:
            anchor += weighted_median(residual[keep], weights[keep])
        else:
            fitted = optimize.least_squares(
                lambda x: (times_in - x[0] - numbers_in * x[1]) * weights_in,
                [anchor, period], loss="soft_l1", f_scale=0.004,
                xtol=1e-13, ftol=1e-13, gtol=1e-13)
            anchor, period = map(float, fitted.x)
    anchor %= period
    bpm = 60.0 / (period * subdivision)
    numbers = np.rint((times - anchor) / period)
    residual = times - anchor - numbers * period
    inlier = np.abs(residual) <= CRITERIA["dominantGridInlierSelectionMs"] / 1000.0
    absolute_ms = np.abs(residual[inlier]) * 1000.0
    concentration = phase_score(times, weights, 1 / period)
    coverage = float(weights[inlier].sum() / weights.sum())
    median = float(np.median(absolute_ms)) if len(absolute_ms) else None
    p95 = float(np.percentile(absolute_ms, 95)) if len(absolute_ms) else None
    windows = []
    for start in np.arange(0, duration, CRITERIA["windowSeconds"]):
        end = min(float(start + CRITERIA["windowSeconds"]), duration)
        if end - start < 10:
            continue
        selected_window = inlier & (times >= start) & (times < end)
        scorable = np.count_nonzero(selected_window) >= max(10, (end - start) * 0.35)
        item = {"startSeconds": float(start), "endSeconds": end,
                "dominantGridOnsets": int(np.count_nonzero(selected_window)), "scorable": bool(scorable)}
        if scorable:
            item["medianSignedResidualMs"] = weighted_median(residual[selected_window], weights[selected_window]) * 1000
            item["p95AbsoluteResidualMs"] = float(np.percentile(np.abs(residual[selected_window]) * 1000, 95))
            n = numbers[selected_window]
            slope = np.polyfit(n, times[selected_window], 1)[0]
            item["localLinearFitBpm"] = float(60 / (slope * subdivision))
        windows.append(item)
    scorable_fraction = sum(x["endSeconds"] - x["startSeconds"] for x in windows if x["scorable"]) / duration
    phase_deviation = max((abs(x["medianSignedResidualMs"]) for x in windows if x["scorable"]), default=float("inf"))
    checks = [
        (concentration >= CRITERIA["minimumWeightedPhaseConcentration"], "Weak overall pulse phase concentration."),
        (coverage >= CRITERIA["minimumWeightedOnsetCoverageWithin30ms"], "Too many strong attacks fall outside the dominant grid."),
        (median is not None and median <= CRITERIA["maximumDominantGridMedianAbsoluteResidualMs"], "Median onset-grid error is too large."),
        (p95 is not None and p95 <= CRITERIA["maximumDominantGridP95AbsoluteResidualMs"], "95th percentile onset-grid error is too large."),
        (phase_deviation <= CRITERIA["maximumWindowMedianPhaseDeviationMs"], "Segment phase drift is too large."),
        (scorable_fraction >= CRITERIA["minimumScorableDurationFraction"], "Too much duration lacks a supported grid."),
    ]
    failures.extend(reason for passed, reason in checks if not passed)
    return {"accepted": not failures, "failures": failures, "fittedBpm": bpm,
            "beatPeriodSeconds": period * subdivision,
            "attackGridPeriodSeconds": period,
            "selectedSubdivisionPulsesPerBeat": subdivision,
            "risingAttackGridAnchorSeconds": anchor,
            "anchorMeaning": "Estimated repeated low-band attack landmark modulo one selected attack-grid period; quarter-beat parity is ambiguous when subdivision=2. Not an annotated bar downbeat or proof of perceptual beat phase.",
            "fixedBpmForFit": fixed_bpm,
            "pulseInterpretationRangeBpm": [minimum_bpm, maximum_bpm],
            "alternativePulseRates": alternatives,
            "halfDoubleTimeBoundary": "Harmonically related pulse rates may share phase concentration; meter is not independently recognized.",
            "weightedPhaseConcentration": concentration, "weightedOnsetCoverageWithin30ms": coverage,
            "dominantGridMedianAbsoluteResidualMs": median, "dominantGridP95AbsoluteResidualMs": p95,
            "allOnsetsMedianAbsoluteResidualMs": float(np.median(np.abs(residual)) * 1000),
            "allOnsetsP95AbsoluteResidualMs": float(np.percentile(np.abs(residual), 95) * 1000),
            "maximumWindowMedianPhaseDeviationMs": phase_deviation if math.isfinite(phase_deviation) else None,
            "scorableDurationFraction": scorable_fraction, "windows": windows,
            "onsets": [{"timeSeconds": float(t), "weight": float(w),
                        "residualMs": float(r * 1000), "dominantGridInlier": bool(k)}
                       for t, w, r, k in zip(times, weights, residual, inlier)]}


def analyze(path: Path, minimum_bpm: float = 75.0, maximum_bpm: float = 150.0,
            target_bpm: float = None) -> Dict[str, Any]:
    path = path.resolve()
    before = sha256(path)
    audio, rate = sf.read(path, dtype="float32", always_2d=True)
    if not np.isfinite(audio).all() or len(audio) < rate:
        raise ValueError("Audio must be finite and at least one second long.")
    duration = len(audio) / rate
    mono = np.mean(audio, axis=1, dtype=np.float64)
    peaks = [float(np.max(abs(audio[:, c]))) for c in range(audio.shape[1])]
    times, weights, extractor = extract_onsets(mono, rate)
    fitted = fit_grid(times, weights, duration, minimum_bpm, maximum_bpm)
    fixed = fit_grid(times, weights, duration, minimum_bpm, maximum_bpm, target_bpm) if target_bpm else None
    if fixed is not None and "fittedBpm" in fitted:
        fixed["freeFitTempoDifferenceFromTargetBpm"] = fitted["fittedBpm"] - target_bpm
        if abs(fitted["fittedBpm"] - target_bpm) > CRITERIA["maximumTargetTempoErrorBpmAfterPreparation"]:
            fixed["accepted"] = False
            fixed["failures"].append("Free-fit tempo differs too much from the target; do not relabel the recording.")
    after = sha256(path)
    if before != after:
        raise ValueError("Source changed during analysis.")
    return {"type": "acoustic_low_band_onset_grid_review", "source": str(path),
            "sha256": before, "sourceHashUnchanged": True, "sampleRate": rate,
            "channels": audio.shape[1], "durationSeconds": duration,
            "samplePeaksLinearByChannel": peaks,
            "acceptanceCriteria": CRITERIA, "criteriaAreClinicalThresholds": False,
            "extractor": extractor, "freeTempoGrid": fitted, "targetTempoGrid": fixed,
            "humanListeningOrBeatAnnotationPerformed": False,
            "clinicalOrProductivityValidationPerformed": False}


def self_test() -> Dict[str, Any]:
    rate = 4000
    rng = np.random.default_rng(250611)
    duration = 70.0
    time = np.arange(int(duration * rate)) / rate
    kick_time = np.arange(int(.18 * rate)) / rate
    kick = .7 * np.sin(2 * np.pi * (65 * kick_time - 60 * kick_time ** 2)) * np.exp(-kick_time * 32)
    def make(onsets):
        audio = rng.normal(0, .001, len(time))
        for onset in onsets:
            start = round(onset * rate)
            if start + len(kick) < len(audio):
                audio[start:start + len(kick)] += kick
        return audio
    known = .137 + np.arange(139) * .5
    times, weights, _ = extract_onsets(make(known), rate)
    regular = fit_grid(times, weights, duration)
    anchor_error = abs(((regular["risingAttackGridAnchorSeconds"] - .137 + .25) % .5) - .25)
    assert regular["accepted"], regular["failures"]
    assert abs(regular["fittedBpm"] - 120) < .003
    assert anchor_error < .015, anchor_error
    eighth_times = .137 + np.arange(279) * .25
    t, w, _ = extract_onsets(make(eighth_times), rate)
    eighth = fit_grid(t, w, duration)
    assert eighth["accepted"], eighth["failures"]
    assert abs(eighth["fittedBpm"] - 120) < .003
    assert eighth["selectedSubdivisionPulsesPerBeat"] == 2
    # Independently generated accelerating inter-onset periods, not the model
    # used in the fit. The grid is intentionally impossible to fit globally.
    drift_times = [.137]
    while drift_times[-1] < duration - .5:
        tempo = 120 + 3.0 * drift_times[-1] / duration
        drift_times.append(drift_times[-1] + 60 / tempo)
    t, w, _ = extract_onsets(make(drift_times), rate)
    drift = fit_grid(t, w, duration)
    assert not drift["accepted"], "Accelerating kick train must be refused."
    noisy = rng.normal(0, .03, len(time))
    t, w, _ = extract_onsets(noisy, rate)
    noise = fit_grid(t, w, duration)
    assert not noise["accepted"], "Random noise must be refused."
    return {"type": "independent_synthetic_kick_grid_checks", "passed": True,
            "checks": 4, "known120BpmAccepted": regular,
            "known120BpmEighthNoteAttacksAccepted": eighth,
            "annotatedAnchorSeconds": .137, "measuredAnchorErrorSeconds": anchor_error,
            "accelerating120To123BpmRefused": drift, "randomNoiseRefused": noise,
            "boundary": "Synthetic tests check timing and refusals, not real-song meter recognition, listening quality or efficacy."}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--minimum-bpm", type=float, default=75.0)
    parser.add_argument("--maximum-bpm", type=float, default=150.0)
    parser.add_argument("--target-bpm", type=float)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if not args.self_test and args.source is None:
        parser.error("source is required unless --self-test is selected")
    try:
        result = self_test() if args.self_test else analyze(args.source, args.minimum_bpm, args.maximum_bpm, args.target_bpm)
    except (ValueError, OSError, sf.LibsndfileError) as error:
        parser.exit(2, "verify_beat_grid: {}\n".format(error))
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    grid = result.get("freeTempoGrid", {})
    print(json.dumps({"report": str(args.report.resolve()), "passed": result.get("passed"),
                      "fittedBpm": grid.get("fittedBpm"), "accepted": grid.get("accepted"),
                      "failures": grid.get("failures")}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
