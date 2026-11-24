#!/usr/bin/env python3
"""Inspect local music files without uploading, modifying, or playing them.

This is an engineering QA report, not a listening test, a genre classifier, a
beat-grid certification, or evidence of an ADHD/productivity benefit. All input
audio remains local. Tempo is an onset-autocorrelation estimate with explicit
half/double-time alternatives. A requested generator BPM is not verification.

Example:
  .venv-audio/bin/python Scripts/audio_review.py /path/to/*.wav \
    --output Research/audio-quality-review.json --expected-bpm 120

Optional --labels accepts a JSON object mapping a basename or absolute path to
metadata such as title, genre, model and generation. These are supplied labels,
not classifications inferred from audio. Per-file JSON results are cached under
Verification/audio-review-*.json and reused only for the same hash and settings.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import scipy
from scipy import signal
from scipy.ndimage import median_filter
import soundfile as sf


ANALYZER_VERSION = 3
PROJECT = Path(__file__).resolve().parent.parent
DOCUMENTATION = [
    {"url": "https://github.com/scipy/scipy/blob/v1.13.1/doc/source/tutorial/signal.rst",
     "via": "Context7 /scipy/scipy/v1.13.1", "checkedOn": "2026-11-19",
     "usedFor": "Welch PSD, STFT, correlation, filtering and Hilbert envelope methods"},
    {"url": "https://github.com/bastibe/python-soundfile/blob/0.13.1/doc/index.rst",
     "via": "Context7 /bastibe/python-soundfile/0.13.1", "checkedOn": "2026-11-19",
     "usedFor": "Container metadata and float32 frames-by-channels reads"},
    {"url": "https://ffmpeg.org/ffmpeg-filters.html#loudnorm",
     "checkedOn": "2026-11-19",
     "usedFor": "FFmpeg loudnorm input integrated LUFS, LRA and true-peak analysis; output discarded"},
]


def db_amplitude(value: float) -> Optional[float]:
    return None if value <= 0 or not math.isfinite(value) else 20 * math.log10(value)


def db_power(value: float) -> Optional[float]:
    return None if value <= 0 or not math.isfinite(value) else 10 * math.log10(value)


def finite_or_none(value: Any) -> Optional[float]:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def executable(name: str) -> Optional[str]:
    found = shutil.which(name)
    fallback = Path("/opt/homebrew/bin") / name
    return found or (str(fallback) if fallback.is_file() else None)


def write_json(path: Path, value: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(path.parent),
                                     prefix=".audio-review-", suffix=".json", delete=False) as handle:
        temporary = Path(handle.name)
        try:
            json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.write("\n")
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def ffprobe_metadata(path: Path) -> Dict[str, Any]:
    binary = executable("ffprobe")
    if not binary:
        return {"measured": False, "reason": "ffprobe unavailable"}
    command = [binary, "-v", "error", "-show_entries",
               "stream=index,codec_name,codec_type,sample_fmt,sample_rate,channels,channel_layout,"
               "bits_per_sample,bits_per_raw_sample,bit_rate:format=format_name,duration,size,bit_rate",
               "-of", "json", str(path)]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
    if completed.returncode:
        return {"measured": False, "reason": completed.stderr.strip()[:500]}
    return {"measured": True, **json.loads(completed.stdout)}


def loudness_metrics(path: Path, duration: float) -> Dict[str, Any]:
    binary = executable("ffmpeg")
    if not binary:
        return {"measured": False, "reason": "FFmpeg unavailable"}
    command = [binary, "-hide_banner", "-nostats", "-threads", "2", "-i", str(path),
               "-map", "0:a:0", "-af", "loudnorm=I=-20:TP=-2:LRA=11:print_format=json",
               "-f", "null", "-"]
    try:
        completed = subprocess.run(command, capture_output=True, text=True,
                                   timeout=max(120, int(duration * 2)), check=False)
        match = re.search(r'\{\s*"input_i".*?\}', completed.stderr, flags=re.DOTALL)
        if completed.returncode or not match:
            raise ValueError("FFmpeg did not return loudnorm input measurements")
        parsed = json.loads(match.group(0))
        return {
            "measured": True,
            "integratedLufs": finite_or_none(parsed.get("input_i")),
            "truePeakDbtp": finite_or_none(parsed.get("input_tp")),
            "loudnessRangeLu": finite_or_none(parsed.get("input_lra")),
            "inputThresholdLufs": finite_or_none(parsed.get("input_thresh")),
            "method": "FFmpeg loudnorm EBU R128 input analysis; rendered output discarded",
            "normalizationApplied": False,
        }
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        return {"measured": False, "reason": str(error)}


def read_audio(path: Path, probe: Dict[str, Any]) -> Tuple[np.ndarray, int, Dict[str, Any]]:
    """Decode locally, preserving the original container/codec in the report.

    A file extension is never treated as evidence of PCM/WAV or a codec. MP4,
    Opus, or other inputs unsupported by libsndfile are decoded by FFmpeg into
    an exclusive temporary float32 WAV. That analysis copy is removed immediately
    after loading; the original file is never rewritten or normalized.
    """
    try:
        info = sf.info(str(path))
        audio, rate = sf.read(str(path), dtype="float32", always_2d=True)
        return audio, rate, {"decoder": "libsndfile", "sourceSoundfileFormat": info.format,
                             "sourceSoundfileSubtype": info.subtype,
                             "temporaryPcmUsed": False, "normalizationApplied": False}
    except (OSError, RuntimeError, sf.LibsndfileError) as first_error:
        binary = executable("ffmpeg")
        if not binary:
            raise ValueError("libsndfile cannot decode this file and FFmpeg is unavailable: " + str(first_error))
        with tempfile.TemporaryDirectory(prefix="audio-review-pcm-") as temporary:
            decoded = Path(temporary) / "analysis-pcm.wav"
            command = [binary, "-hide_banner", "-v", "error", "-n", "-threads", "2", "-i", str(path),
                       "-map", "0:a:0", "-vn", "-c:a", "pcm_f32le", "-f", "wav", str(decoded)]
            completed = subprocess.run(command, capture_output=True, text=True, timeout=300, check=False)
            if completed.returncode:
                raise ValueError("FFmpeg local decode failed: " + completed.stderr.strip()[:500])
            audio, rate = sf.read(str(decoded), dtype="float32", always_2d=True)
        return audio, rate, {"decoder": "FFmpeg to temporary PCM; libsndfile read",
                             "sourceSoundfileFormat": None, "sourceSoundfileSubtype": None,
                             "temporaryPcmUsed": True, "temporaryPcmEncoding": "WAV IEEE float32",
                             "temporaryPcmRemoved": True, "normalizationApplied": False,
                             "sourceContainerAndCodecAreInFfprobe": True}


def runs(mask: np.ndarray, step: float, minimum: float = 0) -> List[Dict[str, float]]:
    changes = np.diff(np.concatenate(([False], mask.astype(bool), [False])).astype(np.int8))
    starts = np.flatnonzero(changes == 1)
    ends = np.flatnonzero(changes == -1)
    return [{"startSeconds": float(start * step), "endSeconds": float(end * step),
             "durationSeconds": float((end - start) * step)}
            for start, end in zip(starts, ends) if (end - start) * step >= minimum]


def sample_and_level_metrics(audio: np.ndarray, sample_rate: int) -> Dict[str, Any]:
    absolute = np.abs(audio)
    peak = float(np.max(absolute))
    energy = float(np.mean(audio * audio, dtype=np.float64))
    near_clip = np.any(absolute >= 0.9999, axis=1)
    clipping_runs = runs(near_clip, 1 / sample_rate)
    block = max(1, int(round(sample_rate * 0.1)))
    count = len(audio) // block
    energies = np.mean(audio[:count * block].reshape(count, block, audio.shape[1]) ** 2,
                       axis=(1, 2), dtype=np.float64)
    levels = 10 * np.log10(np.maximum(energies, 1e-18))
    duration = len(audio) / sample_rate
    silence = runs(levels < -60, block / sample_rate, minimum=0.5)
    internal_silence = [item for item in silence
                        if item["startSeconds"] >= 2 and item["endSeconds"] <= duration - 2]
    seconds_count = count // 10
    second_energies = energies[:seconds_count * 10].reshape(seconds_count, 10).mean(axis=1)
    second_levels = 10 * np.log10(np.maximum(second_energies, 1e-18))
    body = second_levels[5:-5] if len(second_levels) > 12 else second_levels
    body = body[body > -50]
    steps = np.diff(second_levels)
    events = []
    for index, delta in enumerate(steps):
        event_time = index + 1
        if (5 <= event_time <= duration - 5 and abs(delta) >= 5
                and min(second_levels[index:index + 2]) > -50):
            event = {"atSeconds": float(event_time), "changeDb": float(delta),
                     "beforeRmsDbfs": float(second_levels[index]),
                     "afterRmsDbfs": float(second_levels[index + 1])}
            if events and event_time - events[-1]["atSeconds"] < 3:
                if abs(delta) > abs(events[-1]["changeDb"]):
                    events[-1] = event
            else:
                events.append(event)
    if len(second_levels) > 12:
        body_steps = np.abs(np.diff(second_levels[5:-5]))
    else:
        body_steps = np.abs(steps)
    return {
        "allFinite": bool(np.isfinite(audio).all()),
        "samplePeakLinear": peak,
        "samplePeakDbfs": db_amplitude(peak),
        "rmsDbfs": db_power(energy),
        "crestFactorDb": db_amplitude(peak) - db_power(energy) if peak > 0 and energy > 0 else None,
        "dcOffsetPerChannel": [float(item) for item in audio.mean(axis=0, dtype=np.float64)],
        "samplesAtOrAboveFullScale": int(np.count_nonzero(absolute >= 1)),
        "nearFullScaleSamplesThreshold": 0.9999,
        "nearFullScaleSamples": int(np.count_nonzero(absolute >= 0.9999)),
        "longestNearFullScaleRunSeconds": max((item["durationSeconds"] for item in clipping_runs), default=0),
        "clippingInterpretation": "Threshold counts flag numerical full-scale values, not a listening diagnosis of distortion.",
        "silence": {"thresholdRmsDbfs": -60, "blockSeconds": block / sample_rate,
                    "minimumDurationSeconds": 0.5, "intervals": silence[:100],
                    "internalIntervals": internal_silence[:100],
                    "totalSilentSeconds": float(sum(item["durationSeconds"] for item in silence))},
        "levelVariation": {
            "method": "Non-overlapping 1-second broadband RMS, not EBU short-term LUFS",
            "edgeSecondsExcludedFromBody": 5,
            "bodyRms5to95PercentileRangeDb": float(np.percentile(body, 95) - np.percentile(body, 5)) if body.size else None,
            "adjacent1sChangeMedianDb": float(np.median(body_steps)) if body_steps.size else None,
            "adjacent1sChange95PercentileDb": float(np.percentile(body_steps, 95)) if body_steps.size else None,
            "adjacent1sChangeMaxDb": float(np.max(body_steps)) if body_steps.size else None,
            "changesAtLeast5Db": events[:100],
            "interpretation": "Heuristic review points; instrumentation and intended transitions can produce these changes.",
        },
        "loopBoundary": {
            "firstToLastSampleMaxDifference": float(np.max(np.abs(audio[0] - audio[-1]))),
            "firstSecondRmsDbfs": float(second_levels[0]) if second_levels.size else None,
            "lastSecondRmsDbfs": float(second_levels[-1]) if second_levels.size else None,
            "seamlessLoopVerified": False,
        },
    }


def stereo_summary(audio: np.ndarray) -> Dict[str, Any]:
    if audio.shape[1] == 1:
        return {"channelCount": 1, "monoInput": True,
                "leftRightCorrelation": 1.0, "monoFoldRetentionPowerRatio": 1.0,
                "monoFoldLevelChangeDb": 0.0, "sideToMidPowerRatio": 0.0}
    left, right = audio[:, 0], audio[:, 1]
    left_mean = float(left.mean(dtype=np.float64))
    right_mean = float(right.mean(dtype=np.float64))
    l_power = float(np.einsum("i,i->", left, left, dtype=np.float64)) / len(left) - left_mean ** 2
    r_power = float(np.einsum("i,i->", right, right, dtype=np.float64)) / len(right) - right_mean ** 2
    covariance = float(np.einsum("i,i->", left, right, dtype=np.float64)) / len(left) - left_mean * right_mean
    average = max(0, (l_power + r_power) / 2)
    mid = max(0, (l_power + r_power + 2 * covariance) / 4)
    side = max(0, (l_power + r_power - 2 * covariance) / 4)
    correlation = covariance / math.sqrt(l_power * r_power) if l_power > 0 and r_power > 0 else None
    retention = mid / average if average > 1e-16 else None
    return {
        "channelCount": int(audio.shape[1]), "monoInput": False,
        "leftRightCorrelation": min(1, max(-1, correlation)) if correlation is not None else None,
        "leftVsRightLevelDb": db_power(l_power / r_power) if l_power > 0 and r_power > 0 else None,
        "monoFoldRetentionPowerRatio": retention,
        "monoFoldLevelChangeDb": db_power(retention) if retention is not None else None,
        "sideToMidPowerRatio": side / mid if mid > 1e-16 else None,
        "interpretation": "Mono fold is (L+R)/2. Uncorrelated stereo normally loses about 3 dB; a loss alone is not a defect.",
    }


def resampled(audio: np.ndarray, source_rate: int, destination_rate: int) -> np.ndarray:
    common = math.gcd(source_rate, destination_rate)
    return signal.resample_poly(audio, destination_rate // common, source_rate // common, axis=0)


def spectral_balance(audio: np.ndarray, sample_rate: int) -> Dict[str, Any]:
    averaged = None
    weights = 0
    nperseg = min(4096, len(audio))
    for start in range(0, len(audio), sample_rate * 8):
        section = audio[start:start + sample_rate * 8]
        if len(section) < nperseg:
            continue
        frequencies, spectrum = signal.welch(section, fs=sample_rate, nperseg=nperseg,
                                             noverlap=nperseg // 2, axis=0, scaling="density")
        power = spectrum.mean(axis=1)
        averaged = power.astype(np.float64) * len(section) if averaged is None else averaged + power * len(section)
        weights += len(section)
    if averaged is None or weights == 0:
        return {"measured": False}
    power = averaged / weights
    upper_frequency = min(20_000, sample_rate / 2)
    all_band = (frequencies >= 20) & (frequencies <= upper_frequency)
    total = float(np.sum(power[all_band]))
    def fraction(low: float, high: float) -> Optional[float]:
        return float(np.sum(power[(frequencies >= low) & (frequencies < high) & all_band])) / total if total > 0 else None
    centroid = float(np.sum(frequencies[all_band] * power[all_band]) / total) if total > 0 else None
    accumulated = np.cumsum(power[all_band])
    rolloff = float(frequencies[all_band][min(int(np.searchsorted(accumulated, total * 0.85)), len(accumulated) - 1)]) if total > 0 else None
    return {
        "measured": True, "method": "Eight-second chunk-averaged Welch power spectra, channel-power average",
        "analyzedFrequencyRangeHz": [20, upper_frequency],
        "spectralCentroidHz": centroid, "spectralRolloff85Hz": rolloff,
        "powerFractions": {"20to150Hz": fraction(20, 150), "150to1000Hz": fraction(150, 1000),
                           "1000to8000Hz": fraction(1000, 8000), "above8000Hz": fraction(8000, sample_rate / 2 + 1)},
        "interpretation": "Spectral balance descriptors; these do not identify instruments, vocals, harshness, or genre by themselves.",
    }


def autocorrelation_candidates(envelope: np.ndarray, rate: float) -> List[Dict[str, float]]:
    centered = envelope.astype(np.float64) - float(envelope.mean())
    denominator = float(np.dot(centered, centered))
    if len(centered) < rate * 3 or denominator < 1e-12:
        return []
    correlation = signal.correlate(centered, centered, mode="full", method="fft")[len(centered) - 1:]
    correlation /= denominator
    low = max(2, int(math.ceil(rate * 60 / 220)))
    high = min(len(correlation) - 2, int(math.floor(rate * 60 / 40)))
    indices, _ = signal.find_peaks(correlation[low:high + 1], distance=2, prominence=0.015)
    indices = list(indices + low)
    maximum = int(np.argmax(correlation[low:high + 1])) + low
    if maximum not in indices:
        indices.append(maximum)
    result = []
    for index in indices:
        if correlation[index] <= 0:
            continue
        denominator_peak = correlation[index - 1] - 2 * correlation[index] + correlation[index + 1]
        adjustment = 0.5 * (correlation[index - 1] - correlation[index + 1]) / denominator_peak if abs(denominator_peak) > 1e-12 else 0
        lag = index + float(np.clip(adjustment, -0.5, 0.5))
        bpm = 60 * rate / lag
        if not 39 <= bpm <= 222:
            continue
        score = float(correlation[index])
        for multiple, weight in [(2, 0.25), (4, 0.1)]:
            target = int(round(lag * multiple))
            if target < len(correlation):
                score += weight * max(0, float(correlation[target]))
        result.append({"bpm": float(bpm), "autocorrelation": float(correlation[index]), "periodicityScore": score})
    return sorted(result, key=lambda item: item["periodicityScore"], reverse=True)[:8]


def tempo_metrics(audio: np.ndarray, sample_rate: int, expected_bpm: Optional[float]) -> Dict[str, Any]:
    # Analyze one energetic channel rather than canceling anti-phase components
    # by folding stereo to mono before onset detection.
    powers = np.mean(audio * audio, axis=0, dtype=np.float64)
    channel = int(np.argmax(powers))
    analysis_rate = 11_025
    mono = resampled(audio[:, channel], sample_rate, analysis_rate)
    window = 1024
    hop = 256
    frequencies, frame_times, transform = signal.stft(mono, fs=analysis_rate, window="hann",
                                                     nperseg=window, noverlap=window - hop,
                                                     boundary=None, padded=False)
    selected = (frequencies >= 30) & (frequencies <= 5000)
    magnitudes = np.abs(transform[selected])
    compressed = np.log1p(100 * magnitudes)
    flux = np.mean(np.maximum(np.diff(compressed, axis=1), 0), axis=0)
    rate = analysis_rate / hop
    baseline_size = max(3, int(round(rate * 0.5)) | 1)
    envelope = np.maximum(flux - median_filter(flux, size=baseline_size, mode="nearest"), 0)
    candidates = autocorrelation_candidates(envelope, rate)
    base = {
        "method": "Positive log-magnitude spectral flux, local-median subtraction, normalized autocorrelation",
        "analysisChannelZeroBased": channel, "onsetFramesPerSecond": rate,
        "searchedBpmRange": [40, 220], "requestedBpm": expected_bpm,
        "candidates": candidates, "beatLevelVerified": False, "beatAnchorVerified": False,
        "sufficientForBeatLockedAM": False,
        "interpretation": "Estimated periodicity only. Half/double-time and subdivisions are ambiguous; no independent beat-grid verification is performed.",
    }
    if not candidates:
        return {**base, "periodicityConfidence": "unavailable", "estimatedDominantBpm": None,
                "reason": "No sufficiently periodic onset pattern detected"}
    chosen = candidates[0]["bpm"]
    alternatives = [chosen * factor for factor in [0.5, 1, 2] if 35 <= chosen * factor <= 240]
    windows = []
    window_frames = int(round(30 * rate))
    step = int(round(15 * rate))
    for start in range(0, max(1, len(envelope) - window_frames + 1), step):
        section = envelope[start:start + window_frames]
        local = autocorrelation_candidates(section, rate)
        if not local:
            continue
        raw = local[0]["bpm"]
        folded = min([raw * factor for factor in [0.25, 0.5, 1, 2, 4]], key=lambda value: abs(math.log(value / chosen)))
        windows.append({"startSeconds": start / rate, "durationSeconds": len(section) / rate,
                        "rawBpm": raw, "foldedToDominantTempoFamilyBpm": folded,
                        "autocorrelation": local[0]["autocorrelation"]})
    folded_values = np.asarray([item["foldedToDominantTempoFamilyBpm"] for item in windows])
    median_bpm = float(np.median(folded_values)) if folded_values.size else chosen
    mad = float(np.median(np.abs(folded_values - median_bpm))) if folded_values.size else None
    stable_fraction = float(np.mean(np.abs(folded_values / chosen - 1) < 0.03)) if folded_values.size else None
    correlation = candidates[0]["autocorrelation"]
    confidence = "low"
    if correlation >= 0.25 and stable_fraction is not None and stable_fraction >= 0.65:
        confidence = "moderate"
    if correlation >= 0.5 and stable_fraction is not None and stable_fraction >= 0.85:
        confidence = "high-periodicity; beat-level-unverified"
    weights = np.maximum(envelope.astype(np.float64), 0)
    times = frame_times[1:1 + len(envelope)]
    vector = np.sum(weights * np.exp(2j * np.pi * times * chosen / 60))
    concentration = float(abs(vector) / weights.sum()) if weights.sum() > 0 else None
    suggested_anchor = float((np.angle(vector) % (2 * np.pi)) / (2 * np.pi) * 60 / chosen) if concentration is not None else None
    return {
        **base, "estimatedDominantBpm": chosen, "halfDoubleAlternativesBpm": alternatives,
        "periodicityConfidence": confidence, "windowSeconds": 30, "windowHopSeconds": 15,
        "windowEstimates": windows, "foldedWindowMedianBpm": median_bpm,
        "foldedWindowMedianAbsoluteDeviationBpm": mad, "windowsWithin3PercentOfDominantFamily": stable_fraction,
        "windowStabilityInterpretation": "Window estimates can switch between rhythmic subdivisions (including ratios other than 2:1). Disagreement is not automatically real tempo drift; folding here uses half/double only.",
        "matchesRequestedTempoFamilyWithin3Percent": min(abs(value / expected_bpm - 1) for value in alternatives) < 0.03 if expected_bpm else None,
        "suggestedGridOffsetSeconds": suggested_anchor,
        "onsetPhaseConcentrationOnSuggestedGrid": concentration,
        "anchorBoundary": "Heuristic onset phase, not a confirmed beat/downbeat. It must not be supplied to --tempo-verified without verification.",
        "spectralFlatnessMedian": float(np.median(np.exp(np.mean(np.log(magnitudes ** 2 + 1e-14), axis=0))
                                                   / np.mean(magnitudes ** 2 + 1e-14, axis=0))),
    }


def modulation_metrics(audio_4k: np.ndarray) -> Dict[str, Any]:
    sample_rate = 4000
    filtered = signal.sosfiltfilt(signal.butter(4, [200, 1000], btype="bandpass", fs=sample_rate,
                                              output="sos"), audio_4k, axis=0)
    envelope_power = np.zeros(len(filtered), dtype=np.float64)
    for channel in range(filtered.shape[1]):
        envelope_power += np.abs(signal.hilbert(filtered[:, channel])) ** 2 / filtered.shape[1]
    envelope = signal.resample_poly(np.sqrt(envelope_power), 1, 20)
    envelope_rate = 200
    if len(envelope) > envelope_rate * 4:
        envelope = envelope[envelope_rate: -envelope_rate]
    mean_envelope = float(envelope.mean())
    envelope -= mean_envelope
    nperseg = min(8192, len(envelope))
    frequencies, power = signal.welch(envelope, fs=envelope_rate, nperseg=nperseg,
                                      noverlap=nperseg // 2, scaling="density")
    local_range = (frequencies >= 8) & (frequencies <= 32)
    broader = (frequencies >= 0.5) & (frequencies <= 64)
    broad_total = float(np.sum(power[broader]))
    targets = {}
    for target in [8, 16, 32]:
        near = np.abs(frequencies - target) <= 0.25
        neighbor = (np.abs(frequencies - target) >= 0.5) & (np.abs(frequencies - target) <= 2)
        target_max = float(np.max(power[near]))
        background = float(np.median(power[neighbor]))
        maximum_index = int(np.flatnonzero(near)[np.argmax(power[near])])
        targets[str(target)] = {
            "targetHz": target,
            "largestBinWithin0_25Hz": float(frequencies[maximum_index]),
            "peakVsNeighborMedianDb": db_power(target_max / background) if background > 0 else None,
            "powerNearTargetFractionOf0_5to64Hz": float(np.sum(power[near])) / broad_total if broad_total > 0 else None,
        }
    indices, _ = signal.find_peaks(power)
    indices = [index for index in indices if broader[index]]
    top = sorted(indices, key=lambda index: power[index], reverse=True)[:10]
    return {
        "method": "200–1000 Hz fourth-order bandpass, per-channel Hilbert envelopes, RMS-channel combination, 200 Hz envelope Welch PSD",
        "envelopeSampleRateHz": envelope_rate, "frequencyResolutionHz": envelope_rate / nperseg,
        "meanBandEnvelopeLinear": mean_envelope, "targetMetrics": targets,
        "dominantEnvelopePeaks0_5to64Hz": [{"hz": float(frequencies[index]),
                                                   "fractionOfSummedPsdBins": float(power[index] / broad_total) if broad_total > 0 else None}
                                                  for index in top],
        "interpretation": "Acoustic envelope descriptors only. A 16 Hz peak does not demonstrate proprietary NEL calibration, neural entrainment, or attention benefits.",
    }


def technical_review_points(result: Dict[str, Any]) -> List[Dict[str, Any]]:
    points = []
    levels = result["sampleAndLevels"]
    loudness = result["loudness"]
    if levels["samplesAtOrAboveFullScale"]:
        points.append({"code": "sample_full_scale", "severity": "review",
                       "reason": "Some decoded samples reach/exceed full scale; inspect for clipping."})
    true_peak = loudness.get("truePeakDbtp")
    if true_peak is not None and true_peak > 0:
        points.append({"code": "true_peak_over_zero", "severity": "review", "valueDbtp": true_peak,
                       "reason": "FFmpeg estimates inter-sample overs above 0 dBTP; listen and preserve headroom before DSP."})
    elif true_peak is not None and true_peak > -1:
        points.append({"code": "limited_headroom", "severity": "information", "valueDbtp": true_peak,
                       "reason": "Less than 1 dB true-peak headroom; no processing has been applied."})
    silence = levels["silence"]["internalIntervals"]
    if silence:
        points.append({"code": "internal_silence", "severity": "review", "intervalCount": len(silence),
                       "reason": "Internal low-level gaps can interrupt continuous playback; intended breaks remain possible."})
    jumps = levels["levelVariation"]["changesAtLeast5Db"]
    if jumps:
        points.append({"code": "rms_steps", "severity": "review", "eventCount": len(jumps),
                       "reason": "One-second RMS changes of at least 5 dB are timestamped for audition, not automatically judged defects."})
    mono = result["stereo"]["low20to150Hz"].get("monoFoldRetentionPowerRatio")
    if mono is not None and mono < 0.125:
        points.append({"code": "low_end_mono_cancellation", "severity": "review", "retainedPowerRatio": mono,
                       "reason": "Low-frequency stereo loses more than 9 dB when folded to mono."})
    if result["tempo"].get("periodicityConfidence") in ["low", "unavailable"]:
        points.append({"code": "uncertain_tempo", "severity": "information",
                       "reason": "Automatic onset periodicity is weak/ambiguous; do not attest the requested BPM."})
    points.append({"code": "audition_and_attention_unverified", "severity": "boundary",
                   "reason": "No actual listening, genre/vocal classification, long-session experience, or attention-effect test has been performed."})
    return points


def analyze(path: Path, labels: Dict[str, Any], expected_bpm: Optional[float]) -> Dict[str, Any]:
    started = time.monotonic()
    if not path.is_file():
        raise ValueError("Input must be an existing local audio file")
    original_hash = sha256(path)
    probe = ffprobe_metadata(path)
    audio, sample_rate, decoding = read_audio(path, probe)
    source_format = probe.get("format", {}).get("format_name", decoding.get("sourceSoundfileFormat"))
    audio_stream = next((item for item in probe.get("streams", []) if item.get("codec_type") == "audio"), {})
    if len(audio) < sample_rate * 3 or audio.shape[1] not in [1, 2] or not np.isfinite(audio).all():
        raise ValueError("At least 3 seconds of finite mono/stereo audio is required")
    result = {
        "analyzerVersion": ANALYZER_VERSION,
        "analyzedAtUtc": datetime.now(timezone.utc).isoformat(),
        "path": str(path), "sha256": original_hash, "suppliedLabels": labels,
        "source": {"container": source_format, "codec": audio_stream.get("codec_name"),
                   "subtype": decoding.get("sourceSoundfileSubtype"), "sampleRate": sample_rate,
                   "channels": audio.shape[1], "frames": len(audio), "durationSeconds": len(audio) / sample_rate,
                   "byteSize": path.stat().st_size, "ffprobe": probe,
                   "framesAndDurationReferToDecodedAnalysis": True,
                   "extensionNotUsedAsFormatEvidence": True},
        "decoding": decoding,
        "sampleAndLevels": sample_and_level_metrics(audio, sample_rate),
        "spectralBalance": spectral_balance(audio, sample_rate),
        "stereo": {"fullBand": stereo_summary(audio)},
        "tempo": tempo_metrics(audio, sample_rate, expected_bpm),
        "semanticReview": {"performed": False, "model": None,
                           "reason": "No local CLAP/Torch stack installed; whole-file engineering QA prioritized over a large model installation.",
                           "genreVerified": False, "vocalsVerifiedAbsent": False},
        "actualListeningPerformed": False, "attentionOrClinicalValidationPerformed": False,
    }
    low_rate = resampled(audio, sample_rate, 4000)
    low_end = signal.sosfiltfilt(signal.butter(4, [20, 150], btype="bandpass", fs=4000, output="sos"), low_rate, axis=0)
    result["stereo"]["low20to150Hz"] = stereo_summary(low_end)
    del low_end
    result["modulationSpectrum"] = modulation_metrics(low_rate)
    del low_rate, audio
    result["loudness"] = loudness_metrics(path, result["source"]["durationSeconds"])
    result["sourceHashUnchanged"] = sha256(path) == original_hash
    if not result["sourceHashUnchanged"]:
        raise ValueError("Input changed during analysis; results were not accepted")
    result["technicalReviewPoints"] = technical_review_points(result)
    result["analysisWallSeconds"] = time.monotonic() - started
    return result


def self_check(output: Path) -> None:
    # Small end-to-end input/output and numeric sanity check, not an extensive
    # implementation-mirroring test suite and not a production music judgment.
    sample_rate = 16_000
    times = np.arange(sample_rate * 12, dtype=np.float64) / sample_rate
    carrier = 0.1 * np.sin(2 * np.pi * 440 * times)
    modulated = carrier * (0.8 + 0.2 * np.cos(2 * np.pi * 16 * times))
    stereo = np.column_stack([modulated, modulated]).astype(np.float32)
    with tempfile.TemporaryDirectory(prefix="audio-review-check-") as temporary:
        path = Path(temporary) / "synthetic-16hz.wav"
        sf.write(str(path), stereo, sample_rate, subtype="FLOAT")
        before = sha256(path)
        result = analyze(path, {"syntheticFixture": True}, None)
        peak = result["modulationSpectrum"]["targetMetrics"]["16"]["largestBinWithin0_25Hz"]
        assert abs(peak - 16) < 0.25
        assert result["source"]["channels"] == 2
        assert result["sampleAndLevels"]["allFinite"]
        assert result["sampleAndLevels"]["samplesAtOrAboveFullScale"] == 0
        assert result["sourceHashUnchanged"] and sha256(path) == before
        assert abs(result["stereo"]["fullBand"]["leftRightCorrelation"] - 1) < 1e-5
        antiphase = stereo_summary(np.column_stack([carrier, -carrier]))
        assert antiphase["monoFoldRetentionPowerRatio"] < 1e-8
        assert not result["actualListeningPerformed"] and not result["attentionOrClinicalValidationPerformed"]
        checks = {"status": "passed", "fixture": "12-second local stereo 440 Hz carrier with 16 Hz AM",
                  "detectedModulationPeakHz": peak, "sourceUnchanged": True,
                  "finiteNumericJson": True, "monoCancellationSanityCheck": True,
                  "fixtureRemovedAfterCheck": True, "largeMLDependenciesInstalled": False}
        write_json(output, checks)
        print(json.dumps(checks), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="*", type=Path)
    parser.add_argument("--output", type=Path, default=PROJECT / "Research/audio-quality-review.json")
    parser.add_argument("--detail-dir", type=Path, default=PROJECT / "Verification")
    parser.add_argument("--labels", type=Path)
    parser.add_argument("--expected-bpm", type=float)
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--no-cache", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        self_check(args.detail_dir / "audio-review-self-check.json")
        return 0
    if not args.files:
        parser.error("Provide local audio file paths, or --self-check")
    if args.expected_bpm is not None and (not math.isfinite(args.expected_bpm) or not 30 <= args.expected_bpm <= 300):
        parser.error("--expected-bpm must be finite and between 30 and 300")
    labels = json.loads(args.labels.read_text()) if args.labels else {}
    if not isinstance(labels, dict):
        parser.error("--labels must be a JSON object keyed by basename or absolute path")
    paths = [path.expanduser().resolve() for path in args.files]
    if args.output.expanduser().resolve() in paths:
        parser.error("The JSON output must not overwrite input audio")
    results = []
    failures = []
    for index, path in enumerate(paths, 1):
        print("[{}/{}] {}".format(index, len(paths), path.name), flush=True)
        try:
            digest = sha256(path)
            supplied = labels.get(str(path), labels.get(path.name, {}))
            if not isinstance(supplied, dict):
                raise ValueError("Per-file labels must be a JSON object")
            expected_bpm = supplied.get("expectedBpm", args.expected_bpm)
            if expected_bpm is not None:
                expected_bpm = float(expected_bpm)
                if not math.isfinite(expected_bpm) or not 30 <= expected_bpm <= 300:
                    raise ValueError("Per-file expectedBpm must be finite and between 30 and 300")
            slug = re.sub(r"[^A-Za-z0-9_-]+", "-", path.stem).strip("-")[:70] or "track"
            detail_path = args.detail_dir / ("audio-review-" + slug + "-" + digest[:12] + ".json")
            result = None
            if not args.no_cache and detail_path.is_file():
                cached = json.loads(detail_path.read_text())
                if (cached.get("analyzerVersion") == ANALYZER_VERSION and cached.get("sha256") == digest
                        and cached.get("tempo", {}).get("requestedBpm") == expected_bpm):
                    result = cached
            if result is None:
                result = analyze(path, supplied, expected_bpm)
            else:
                result["suppliedLabels"] = supplied
                result["path"] = str(path)
                print("  reused identical-hash cached measurements", flush=True)
            write_json(detail_path, result)
            results.append(result)
            print("  duration={:.1f}s LUFS={} truePeak={}dBTP tempo={} confidence={}".format(
                result["source"]["durationSeconds"], result["loudness"].get("integratedLufs"),
                result["loudness"].get("truePeakDbtp"), result["tempo"].get("estimatedDominantBpm"),
                result["tempo"].get("periodicityConfidence")), flush=True)
        except Exception as error:
            failures.append({"path": str(path), "error": str(error)})
            print("  ERROR: " + str(error), file=sys.stderr, flush=True)
    measured_lufs = [item["loudness"].get("integratedLufs") for item in results]
    measured_lufs = [value for value in measured_lufs if value is not None]
    comparison_rows = []
    for item in results:
        samples = item["sampleAndLevels"]
        comparison_rows.append({
            "file": Path(item["path"]).name,
            "suppliedTitle": item["suppliedLabels"].get("title"),
            "suppliedGenre": item["suppliedLabels"].get("requestedGenre"),
            "container": item["source"]["container"], "codec": item["source"].get("codec"),
            "durationSeconds": item["source"]["durationSeconds"],
            "integratedLufs": item["loudness"].get("integratedLufs"),
            "truePeakDbtp": item["loudness"].get("truePeakDbtp"),
            "loudnessRangeLu": item["loudness"].get("loudnessRangeLu"),
            "fullScaleSamples": samples["samplesAtOrAboveFullScale"],
            "internalSilenceCount": len(samples["silence"]["internalIntervals"]),
            "rmsStepAtLeast5DbCount": len(samples["levelVariation"]["changesAtLeast5Db"]),
            "lowFrequencyMonoFoldDb": item["stereo"]["low20to150Hz"].get("monoFoldLevelChangeDb"),
            "estimatedDominantBpm": item["tempo"].get("estimatedDominantBpm"),
            "halfDoubleAlternativesBpm": item["tempo"].get("halfDoubleAlternativesBpm"),
            "periodicityConfidence": item["tempo"]["periodicityConfidence"],
            "beatGridVerified": False, "actualListeningPerformed": False,
            "sourceHashUnchanged": item["sourceHashUnchanged"],
        })
    report = {
        "analyzerVersion": ANALYZER_VERSION, "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
        "scope": "Local full-file engineering QA of supplied downloads, without modifying or uploading source audio",
        "environment": {"python": sys.version.split()[0], "numpy": np.__version__,
                        "scipy": scipy.__version__, "soundfile": sf.__version__, "ffmpeg": executable("ffmpeg")},
        "documentation": DOCUMENTATION, "reviewedFileCount": len(results), "failedFileCount": len(failures),
        "comparisonSummary": {
            "fileCount": len(results),
            "distinctBasenamesIgnoringFileFormat": len({Path(item["path"]).stem for item in results}),
            "integratedLoudnessSpreadLu": max(measured_lufs) - min(measured_lufs) if measured_lufs else None,
            "loudnessMatched": False, "rows": comparison_rows,
        },
        "actualListeningPerformed": False, "semanticGenreOrVocalReviewPerformed": False,
        "attentionOrClinicalValidationPerformed": False, "tracks": results, "failures": failures,
        "boundaries": [
            "These measurements do not establish sound quality preference, genre fit, absence of vocals, or long-session comfort.",
            "Supplied labels and generator prompts are metadata, not findings from audio.",
            "Tempo candidates and suggested beat anchors are estimates and are insufficient for --tempo-verified.",
            "Full-scale/true-peak, silence and RMS-step flags are review points, not automatic judgments of audible faults.",
            "No neural effect calibration, entrainment, ADHD treatment or attention benefit was tested.",
        ],
    }
    write_json(args.output, report)
    print("Saved " + str(args.output), flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
