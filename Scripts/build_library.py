#!/usr/bin/env python3
"""Build or refresh the Focus Music track library: audio copies + library.json.

Example::
    .venv-audio/bin/python Scripts/build_library.py --library <dir> \
        --sources Scripts/library-sources.json [--force-reanalyze]

Each source file is cloned (APFS ``cp -c``; plain copy if that fails) into
``<library>/tracks/<id>.<ext>`` in its original format, then measured:
duration, sample rate and channels (ffprobe), integrated loudness and true
peak (FFmpeg loudnorm analysis via audio_review), sha256, and the acoustic
low-band onset grid of verify_beat_grid. An existing Verification/beat-grid
report for the same sha256 and acceptance criteria is used instead of a new fit.

Derived values, recomputed on every run from the stored measurements:
  gainDb        -18 LUFS minus integrated loudness, lowered when needed so the
                static true peak stays at or below -1 dBTP (gainCapped=true).
  pulseMode     how the focus pulse locks to the music; every track gets one, tried in order:
                "grid"   the global beat grid passed the detector's acceptance criteria
                         (gridVerified), or failed only the 95th-percentile residual check
                         with a median residual of at most 5 ms (relaxed; gridVerified stays
                         false). modulationHz = k*BPM/60, where k is the integer number of
                         pulse cycles per beat that puts it closest to 16 Hz (14-18 Hz);
                         beatOffsetSeconds is the grid phase.
                "follow" the tempo drifts: Scripts/beat_map.py tracks the beats and its map
                         passed beat_map.GATE. beatTimes (s, file time) and
                         pulseCyclesPerBeat c = round(16 Hz x median beat interval);
                         modulationHz = c / median interval (nominal); beatOffsetSeconds =
                         the first beat. The app runs c pulse cycles per beat interval.
                "steady" no reliable beat: modulationHz 16.0, beatOffsetSeconds 0.
                The beat map is made for every track (analysis/<id>.beats.json, reused while
                the audio, the measured tempo and grid phase, and the code of beat_map.py,
                verify_beat_grid.py and loop_points.py are unchanged); for grid tracks it is
                only a check (its agreement with the grid is printed).

Loop points (Scripts/loop_points.py) let the app play each track for 30 minutes
by repeating its middle: loopStartSeconds/loopEndSeconds (bar lines, the end
aligned to the start's beat), loopBars, and loopSeamCorrelation (how alike the
two sides of the seam sound; the app keeps the seam's power flat for it). All
null when no seam passes; such a track plays once. The loop never reaches past
a flag's atSeconds. Results and their measurements are cached in
analysis/<id>.loop.json and reused while the audio, beat grid and flags match.

The measured grid phase is the detector's attack-grid anchor (the catalog's
beatOffsetSeconds on grid tracks; loop points always use it). When the detector
selects two attacks per beat it cannot tell beat from off-beat, so the parity
whose grid attacks carry more summed onset weight is taken as the beat; the
evidence is kept in analysis/<id>.json (beat_map uses the same rule). This is a
heuristic, not a verified downbeat. Numbers that were not measured are null.

Re-runs are idempotent: entries are matched by id, a track whose library copy
already has the source's sha256 is not copied again, measurements are reused
from analysis/<id>.json while it has the source's sha256 and the detector's
current criteria (unless --force-reanalyze is given), entries absent
from the sources file are left untouched, and library.json is replaced
atomically only when its content changes. Catalog fields (title, genre, status,
flags, source, palette, about) follow the sources file on every run; addedAt keeps the
time a track was first added. Source audio is only read.
"""

import argparse
import bisect
from datetime import datetime, timezone
import functools
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any, Callable, Dict, List, Optional, Tuple

SCRIPTS = Path(__file__).resolve().parent
PROJECT = SCRIPTS.parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import audio_review  # noqa: E402  sha256, ffprobe_metadata, loudness_metrics, write_json
import beat_map  # noqa: E402  analyze_beats, BEAT_MAP_VERSION, SETTINGS
import loop_points  # noqa: E402  analyze_loop, LOOP_VERSION
import verify_beat_grid  # noqa: E402  analyze, CRITERIA

LIBRARY_VERSION = 1
TARGET_LUFS = -18.0
TRUE_PEAK_CEILING_DBTP = -1.0
MODULATION_TARGET_HZ = 16.0
MODULATION_RANGE_HZ = (14.0, 18.0)
STEADY_PULSE_HZ = 16.0
RELAXED_GRID_FAILURES = ["95th percentile onset-grid error is too large."]  # the only failure allowed
RELAXED_GRID_MEDIAN_MS = 5.0
# beat_map.py's wording of its one relative check (the map must beat the best single global grid).
MAP_ONLY_NOT_BETTER_THAN_GRID = ["The map is not clearly better than the best single global grid."]
BEAT_RESULT_KEYS = ("accepted", "failures", "beatTimes", "pulseCyclesPerBeat", "modulationHz", "beatOffsetSeconds")
GRID_BPM_RANGE = [75.0, 150.0]  # verify_beat_grid.analyze defaults; reused reports must match
GENRES = ("lofi", "grooves", "electronic")
STATUSES = ("inMix", "new")
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
ENTRY_KEYS = {"id", "title", "genre", "path", "status", "flags", "source", "notes", "about", "palette"}
ABOUT_KEYS = ("vibe", "loop")
FLAG_KEYS = ("code", "atSeconds", "en", "ko")
SOURCE_KEYS = ("service", "songId", "round", "originalPath")
LOOP_KEYS = ("loopStartSeconds", "loopEndSeconds", "loopBars", "loopSeamCorrelation")
HEX_COLOUR = re.compile(r"^#[0-9A-Fa-f]{6}$")

# A song's colours: its own "palette" in the sources file when it has one, else the colours of its
# cover, else one of these picked by its id.
# Saturated mid tone, light tint, deeper accent: reads as a soft gradient on light glass.
CURATED_PALETTES = [
    ["#34D399", "#A7F3D0", "#0EA5E9"],
    ["#F97316", "#FDE047", "#EC4899"],
    ["#6366F1", "#A5B4FC", "#EC4899"],
    ["#14B8A6", "#FDE68A", "#F472B6"],
    ["#3B82F6", "#C4B5FD", "#F0ABFC"],
    ["#FB923C", "#FBCFE8", "#A855F7"],
    ["#10B981", "#FCD34D", "#3B82F6"],
    ["#8B5CF6", "#67E8F9", "#F472B6"],
    ["#FB7185", "#FECDD3", "#818CF8"],
    ["#0EA5E9", "#A5F3FC", "#22C55E"],
    ["#F59E0B", "#FCA5A5", "#7C3AED"],
    ["#06B6D4", "#C084FC", "#FDE68A"],
]


def utc_now() -> str:
    # Whole seconds with Z so Swift's .iso8601 date strategy can parse it.
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def rounded(value: Any, digits: int) -> Optional[float]:
    number = audio_review.finite_or_none(value)
    return None if number is None else round(number, digits)


# Each song's cover picture, when it has one (generated with Suno): Audio/Covers/suno/<songId>.jpeg.
COVERS = PROJECT / "Audio" / "Covers" / "suno"
COVER_PIXELS = 256


def _cover_pixels(path: Path, side: int = 64) -> Optional["np.ndarray"]:
    """The picture as side x side RGB floats in 0...1 (decoded by ffmpeg), or None."""
    import numpy as np
    completed = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-vf", "scale={0}:{0}".format(side),
                                "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True)
    if completed.returncode != 0 or len(completed.stdout) != side * side * 3:
        return None
    return np.frombuffer(completed.stdout, dtype=np.uint8).reshape(-1, 3).astype(np.float64) / 255.0


def palette_from_cover(path: Path) -> Optional[List[str]]:
    """Three colours for the player's drifting background, taken from the cover: a mid tone, a
    light tint and a deeper accent (the same roles as CURATED_PALETTES), so a dark or pale
    picture still reads as a soft gradient on the glass. Deterministic k-means on 64 x 64."""
    import colorsys
    import numpy as np
    pixels = _cover_pixels(path)
    if pixels is None:
        return None
    luma = 0.299 * pixels[:, 0] + 0.587 * pixels[:, 1] + 0.114 * pixels[:, 2]
    order = np.argsort(luma)
    k = 6
    centres = np.array([pixels[order[int((i + 0.5) * len(order) / k)]] for i in range(k)])
    for _ in range(20):
        labels = np.argmin(((pixels[:, None, :] - centres[None, :, :]) ** 2).sum(axis=2), axis=1)
        for i in range(k):
            if np.any(labels == i):
                centres[i] = pixels[labels == i].mean(axis=0)
    counts = np.bincount(labels, minlength=k)
    scored = []
    for i in range(k):
        if counts[i] == 0:
            continue
        h, l, s = colorsys.rgb_to_hls(*centres[i])
        weight = counts[i] * (0.25 + s) * (0.3 if l < 0.08 or l > 0.95 else 1.0)
        scored.append((weight, h, l, s))
    scored.sort(reverse=True)

    def distinct(a, b):
        hue = min(abs(a[1] - b[1]), 1 - abs(a[1] - b[1]))
        return hue > 0.06 or abs(a[2] - b[2]) > 0.18 or abs(a[3] - b[3]) > 0.25

    picks = [scored[0]]
    for candidate in scored[1:]:
        if all(distinct(candidate, chosen) for chosen in picks):
            picks.append(candidate)
        if len(picks) == 3:
            break
    while len(picks) < 3:
        picks.append(picks[0])

    def hexed(h, l, s):
        r, g, b = colorsys.hls_to_rgb(h, min(max(l, 0.0), 1.0), min(max(s, 0.0), 1.0))
        return "#{:02X}{:02X}{:02X}".format(round(r * 255), round(g * 255), round(b * 255))

    mid, second, third = picks
    return [hexed(mid[1], min(max(mid[2], 0.45), 0.68), mid[3]),
            hexed(second[1], min(max(second[2], 0.80), 0.90), second[3]),
            hexed(third[1], min(max(third[2], 0.30), 0.55), third[3])]


def cover_for(item: Dict[str, Any], library: Path) -> Tuple[Optional[str], Optional[List[str]]]:
    """Copies the song's cover (generated with Suno) into the library as a small JPEG (covers/<id>.jpg) and
    returns its catalog path and the palette taken from it; (None, None) without a cover."""
    source = item.get("source") if isinstance(item.get("source"), dict) else {}
    song_id = source.get("songId")
    picture = COVERS / "{}.jpeg".format(song_id) if isinstance(song_id, str) else None
    if picture is None or not picture.is_file():
        return None, None
    relative = "covers/{}.jpg".format(item["id"])
    destination = library / relative
    if not destination.is_file() or destination.stat().st_mtime < picture.stat().st_mtime:
        destination.parent.mkdir(parents=True, exist_ok=True)
        completed = subprocess.run(["/usr/bin/sips", "-s", "format", "jpeg", "-s", "formatOptions", "85",
                                    "-Z", str(COVER_PIXELS), str(picture), "--out", str(destination)],
                                   capture_output=True, text=True)
        if completed.returncode != 0 or not destination.is_file():
            print("  warning: {} cover could not be copied: {}".format(item["id"], completed.stderr.strip()), flush=True)
            return None, None
    return relative, palette_from_cover(picture)


def palette_for(track_id: str) -> List[str]:
    digest = hashlib.sha256(track_id.encode("utf-8")).digest()
    return list(CURATED_PALETTES[int.from_bytes(digest[:8], "big") % len(CURATED_PALETTES)])


def playback_gain(lufs: Optional[float], true_peak: Optional[float]) -> Tuple[Optional[float], bool]:
    if lufs is None or true_peak is None:
        return None, False
    ceiling = TRUE_PEAK_CEILING_DBTP - true_peak
    gain = round(TARGET_LUFS - lufs, 2)
    if gain > ceiling:
        return math.floor(ceiling * 100 + 1e-9) / 100, True
    return gain, False


def modulation_for(bpm: Optional[float], grid_verified: bool) -> Tuple[Optional[float], str]:
    if not grid_verified or bpm is None or bpm <= 0:
        return None, "beat grid did not pass the acceptance criteria"
    cycles = max(1, int(round(MODULATION_TARGET_HZ * 60.0 / bpm)))
    frequency = cycles * bpm / 60.0
    if not MODULATION_RANGE_HZ[0] <= frequency <= MODULATION_RANGE_HZ[1]:
        return None, "k={} gives {:.3f} Hz, outside {}-{} Hz".format(cycles, frequency, *MODULATION_RANGE_HZ)
    return round(frequency, 4), "k={} cycles per beat".format(cycles)


def text(value: Any, where: str, optional: bool = False) -> Optional[str]:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value.strip():
        raise ValueError(where + " must be a non-empty string")
    return value


def load_sources(path: Path, library: Path) -> List[Dict[str, Any]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    entries = document.get("tracks") if isinstance(document, dict) else document
    if not isinstance(entries, list) or not entries:
        raise ValueError("sources must be a non-empty list or an object with a non-empty 'tracks' list")
    seen = set()
    checked = []
    for number, entry in enumerate(entries, 1):
        where = "sources entry {}".format(number)
        if not isinstance(entry, dict):
            raise ValueError(where + " must be an object")
        if set(entry) - ENTRY_KEYS:
            raise ValueError(where + ": unknown keys " + ", ".join(sorted(set(entry) - ENTRY_KEYS)))
        track_id = entry.get("id")
        if not isinstance(track_id, str) or not ID_PATTERN.match(track_id):
            raise ValueError(where + ": id must match " + ID_PATTERN.pattern)
        where = "sources entry '{}'".format(track_id)
        if track_id in seen:
            raise ValueError(where + ": duplicate id")
        seen.add(track_id)
        if entry.get("genre") not in GENRES:
            raise ValueError(where + ": genre must be one of " + ", ".join(GENRES))
        if entry.get("status") not in STATUSES:
            raise ValueError(where + ": status must be one of " + ", ".join(STATUSES))
        source_path = Path(text(entry.get("path"), where + ": path")).expanduser()
        source_path = (source_path if source_path.is_absolute() else PROJECT / source_path).resolve()
        if not source_path.is_file():
            raise ValueError(where + ": audio file not found: " + str(source_path))
        if library == source_path.parent or library in source_path.parents:
            raise ValueError(where + ": source audio must not live inside the library folder")
        suffix = source_path.suffix.lower()
        if not re.match(r"^\.[a-z0-9]{1,5}$", suffix):
            raise ValueError(where + ": unsupported file extension " + repr(source_path.suffix))
        flags = entry.get("flags", [])
        if not isinstance(flags, list):
            raise ValueError(where + ": flags must be a list")
        clean_flags = []
        for flag in flags:
            if not isinstance(flag, dict) or set(flag) - set(FLAG_KEYS):
                raise ValueError(where + ": each flag is an object with keys " + ", ".join(FLAG_KEYS))
            at = flag.get("atSeconds")
            if at is not None and (isinstance(at, bool) or not isinstance(at, (int, float))
                                   or not math.isfinite(at) or at < 0):
                raise ValueError(where + ": flag atSeconds must be a non-negative number or null")
            clean_flags.append({"code": text(flag.get("code"), where + ": flag code"), "atSeconds": at,
                                "en": text(flag.get("en"), where + ": flag en"),
                                "ko": text(flag.get("ko"), where + ": flag ko")})
        source = entry.get("source", {})
        if not isinstance(source, dict) or set(source) - set(SOURCE_KEYS):
            raise ValueError(where + ": source is an object with keys " + ", ".join(SOURCE_KEYS))
        clean_source = {key: text(source.get(key), where + ": source." + key, optional=True) for key in SOURCE_KEYS}
        clean_source["originalPath"] = clean_source["originalPath"] or str(source_path)
        about = entry.get("about", {})
        if not isinstance(about, dict) or set(about) - set(ABOUT_KEYS):
            raise ValueError(where + ": about is an object with keys " + ", ".join(ABOUT_KEYS))
        clean_about = {}
        for key in ABOUT_KEYS:
            line = about.get(key)
            if line is None:
                continue
            if not isinstance(line, dict) or set(line) != {"en", "ko"}:
                raise ValueError(where + ": about." + key + " is an object with en and ko")
            clean_about[key] = {"en": text(line["en"], where + ": about." + key + ".en"),
                                "ko": text(line["ko"], where + ": about." + key + ".ko")}
        palette = entry.get("palette")
        if palette is not None and (not isinstance(palette, list) or len(palette) != 3 or not all(
                isinstance(colour, str) and HEX_COLOUR.match(colour) for colour in palette)):
            raise ValueError(where + ": palette is a list of three \"#RRGGBB\" colours")
        checked.append({"id": track_id, "title": text(entry.get("title"), where + ": title"),
                        "genre": entry["genre"], "status": entry["status"], "sourcePath": source_path,
                        "suffix": suffix, "flags": clean_flags, "source": clean_source,
                        "about": clean_about or None,
                        "palette": [colour.upper() for colour in palette] if palette else None})
    return checked


def existing_grid_reports() -> Dict[str, Path]:
    """sha256 -> Verification report made by the current detector criteria."""
    found = {}
    for path in sorted((PROJECT / "Verification").glob("beat-grid-*.json")):
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        grid = report.get("freeTempoGrid") if isinstance(report, dict) else None
        if (isinstance(grid, dict) and report.get("type") == "acoustic_low_band_onset_grid_review"
                and isinstance(report.get("sha256"), str)
                and report.get("acceptanceCriteria") == verify_beat_grid.CRITERIA
                and grid.get("pulseInterpretationRangeBpm", GRID_BPM_RANGE) == GRID_BPM_RANGE):
            found.setdefault(report["sha256"], path)
    return found


def beat_grid(source: Path, digest: str, reports: Dict[str, Path]) -> Dict[str, Any]:
    report_path = reports.get(digest)
    if report_path is not None:
        report = json.loads(report_path.read_text(encoding="utf-8"))
        origin = {"kind": "existingVerificationReport", "path": str(report_path),
                  "reportSha256": audio_review.sha256(report_path)}
    else:
        report = verify_beat_grid.analyze(source, *GRID_BPM_RANGE)
        origin = {"kind": "freshAnalysis", "detector": str(SCRIPTS / "verify_beat_grid.py"),
                  "detectorSha256": audio_review.sha256(SCRIPTS / "verify_beat_grid.py")}
    if report.get("sha256") != digest:
        raise ValueError("beat-grid report sha256 does not match the source")
    grid = report["freeTempoGrid"]
    period = grid.get("attackGridPeriodSeconds")
    anchor = grid.get("risingAttackGridAnchorSeconds")
    subdivision = grid.get("selectedSubdivisionPulsesPerBeat")
    offset, parity = anchor, None
    if subdivision == 2 and period and anchor is not None:
        weights = [0.0, 0.0]
        for onset in grid.get("onsets", []):
            if onset.get("dominantGridInlier"):
                weights[int(round((onset["timeSeconds"] - anchor) / period)) % 2] += onset["weight"]
        beat_is_odd = weights[1] > weights[0]
        offset = anchor + period if beat_is_odd else anchor
        parity = {"rule": "parity with the larger summed onset weight is taken as the beat",
                  "anchorParityWeight": weights[0], "otherParityWeight": weights[1],
                  "beatOffsetUsesOtherParity": beat_is_odd}
    detail = {key: grid.get(key) for key in (
        "accepted", "failures", "fittedBpm", "beatPeriodSeconds", "selectedSubdivisionPulsesPerBeat",
        "attackGridPeriodSeconds", "risingAttackGridAnchorSeconds", "weightedPhaseConcentration",
        "weightedOnsetCoverageWithin30ms", "dominantGridMedianAbsoluteResidualMs",
        "dominantGridP95AbsoluteResidualMs", "maximumWindowMedianPhaseDeviationMs", "scorableDurationFraction")}
    detail.update({"origin": origin, "beatOffsetSeconds": offset, "beatParity": parity,
                   "decodedDurationSeconds": report.get("durationSeconds"),
                   "onsetCount": (report.get("extractor") or {}).get("onsetCount"),
                   "acceptanceCriteria": report.get("acceptanceCriteria"),
                   "boundary": "Acoustic low-band attack grid. Not an annotated downbeat, meter or perceptual beat phase."})
    return detail


def analyze(source: Path, digest: str, reports: Dict[str, Path]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    probe = audio_review.ffprobe_metadata(source)
    if not probe.get("measured"):
        raise ValueError("ffprobe failed: " + str(probe.get("reason")))
    stream = next((item for item in probe.get("streams", []) if item.get("codec_type") == "audio"), None)
    if stream is None:
        raise ValueError("no audio stream")
    duration = audio_review.finite_or_none(probe.get("format", {}).get("duration"))
    if duration is None or duration <= 0:
        raise ValueError("ffprobe reported no duration")
    loudness = audio_review.loudness_metrics(source, duration)
    if not loudness.get("measured"):
        raise ValueError("loudness analysis failed: " + str(loudness.get("reason")))
    grid = beat_grid(source, digest, reports)
    if audio_review.sha256(source) != digest:
        raise ValueError("source changed during analysis")
    detail = {
        "sha256": digest, "sourcePath": str(source), "analyzedAt": utc_now(),
        "format": {"container": probe.get("format", {}).get("format_name"), "codec": stream.get("codec_name"),
                   "bitsPerSample": stream.get("bits_per_raw_sample") or stream.get("bits_per_sample"),
                   "sampleRate": int(stream["sample_rate"]) if stream.get("sample_rate") else None,
                   "channels": int(stream["channels"]) if stream.get("channels") else None,
                   "durationSeconds": duration, "tool": audio_review.executable("ffprobe")},
        "loudness": dict(loudness, tool=audio_review.executable("ffmpeg")),
        "beatGrid": grid,
        "notMeasured": ["listening quality", "vocals", "attention or clinical effect", "annotated downbeat"],
    }
    return measured_from(detail), detail


def measured_from(detail: Dict[str, Any]) -> Dict[str, Any]:
    """The catalog's measured fields from an analysis report (analysis/<id>.json)."""
    grid, form, loudness = detail["beatGrid"], detail["format"], detail["loudness"]
    return {
        "durationSeconds": rounded(form["durationSeconds"], 3),
        "sampleRate": form["sampleRate"], "channels": form["channels"],
        "integratedLufs": rounded(loudness.get("integratedLufs"), 2),
        "truePeakDbtp": rounded(loudness.get("truePeakDbtp"), 2),
        "bpm": rounded(grid["fittedBpm"], 4),
        "beatOffsetSeconds": rounded(grid["beatOffsetSeconds"], 4),
        "gridVerified": bool(grid["accepted"]),
        "gridMedianResidualMs": rounded(grid["dominantGridMedianAbsoluteResidualMs"], 2),
        "gridP95ResidualMs": rounded(grid["dominantGridP95AbsoluteResidualMs"], 2),
    }


def stored_analysis(library: Path, track_id: str, digest: str) -> Optional[Dict[str, Any]]:
    """analysis/<id>.json when it measured this audio with the detector's current criteria."""
    try:
        detail = json.loads((library / "analysis" / (track_id + ".json")).read_text(encoding="utf-8"))
        grid = detail["beatGrid"]
        if (detail.get("sha256") != digest or grid.get("acceptanceCriteria") != verify_beat_grid.CRITERIA
                or not isinstance(grid.get("failures"), list)):
            return None
        measured_from(detail)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None
    return detail


@functools.lru_cache(maxsize=1)
def beat_map_code() -> Dict[str, str]:
    """sha256 of the scripts a beat map depends on: any change to them makes the maps again."""
    return {name: audio_review.sha256(SCRIPTS / name) for name in ("beat_map.py", "verify_beat_grid.py", "loop_points.py")}


def beat_map_for(item: Dict[str, Any], measured: Dict[str, Any], digest: str, library: Path,
                 force: bool) -> Tuple[Optional[Dict[str, Any]], str]:
    """Scripts/beat_map.py's map, from analysis/<id>.beats.json while its inputs still match."""
    if measured["bpm"] is None:
        return None, "no tempo estimate"
    inputs = {"version": beat_map.BEAT_MAP_VERSION, "code": beat_map_code(), "sha256": digest,
              "bpm": measured["bpm"], "gridBeatOffsetSeconds": measured["beatOffsetSeconds"]}
    cache = library / "analysis" / (item["id"] + ".beats.json")
    if not force and cache.is_file():
        try:
            previous = json.loads(cache.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            previous = None
        if isinstance(previous, dict) and previous.get("inputs") == inputs and isinstance(previous.get("result"), dict):
            return previous, "reused"
    try:
        found = beat_map.analyze_beats(item["sourcePath"], measured["bpm"], measured["beatOffsetSeconds"])
    except Exception as error:  # a track without a beat map still gets a pulse (grid or steady); not cached
        reason = "analysis failed: {}: {}".format(type(error).__name__, error)
        print("  warning: {} beat map {}".format(item["id"], reason), flush=True)
        return {"result": {"accepted": False, "failures": [reason]}}, reason
    report = {"id": item["id"], "analyzedAt": utc_now(), "inputs": inputs,
              "result": {key: found.get(key) for key in BEAT_RESULT_KEYS},
              "quality": found.get("quality"), "gridAgreement": found.get("gridAgreement"),
              "settings": beat_map.SETTINGS, "detail": found.get("detail")}
    audio_review.write_json(cache, report)
    return report, "analyzed"


def pulse_plan(measured: Dict[str, Any], grid_failures: List[str], beats: Optional[Dict[str, Any]],
               beats_note: str) -> Tuple[Dict[str, Any], str]:
    """Catalog pulse fields (pulseMode, modulationHz, beatOffsetSeconds, and for "follow" beatTimes
    and pulseCyclesPerBeat) and a note on why: grid, relaxed grid, follow, else steady."""
    reasons = []
    relaxed = (grid_failures == RELAXED_GRID_FAILURES and measured["gridMedianResidualMs"] is not None
               and measured["gridMedianResidualMs"] <= RELAXED_GRID_MEDIAN_MS)
    if measured["gridVerified"] or relaxed:
        frequency, note = modulation_for(measured["bpm"], True)
        if frequency is not None:
            return ({"pulseMode": "grid", "modulationHz": frequency, "beatOffsetSeconds": measured["beatOffsetSeconds"]},
                    "grid ({}), {}".format("verified" if measured["gridVerified"] else "relaxed: only the p95 check failed", note))
        reasons.append("grid: " + note)
    result = (beats or {}).get("result") or {}
    # Only the map's relative check failed: one global grid fits the attacks about as well as the map,
    # so the tempo is steady and the map is that grid, within the map's own absolute limits. The
    # grid check above failed for reasons of its own (Pocket III: a 22 s drumless intro in a 2-minute
    # file), so the map still beats a steady pulse that ignores the beat.
    steady_tempo = result.get("failures") == MAP_ONLY_NOT_BETTER_THAN_GRID and bool(result.get("beatTimes"))
    if result.get("accepted") or steady_tempo:
        return ({"pulseMode": "follow", "modulationHz": result["modulationHz"],
                 "beatOffsetSeconds": result["beatOffsetSeconds"], "beatTimes": result["beatTimes"],
                 "pulseCyclesPerBeat": result["pulseCyclesPerBeat"]},
                "follow, {} beats, c={} ({} beat map{})".format(
                    len(result["beatTimes"]), result["pulseCyclesPerBeat"], beats_note,
                    "; steady tempo, as good as one global grid" if steady_tempo else ""))
    reasons.append("beat map: " + ("; ".join(result.get("failures") or []) or beats_note))
    return ({"pulseMode": "steady", "modulationHz": STEADY_PULSE_HZ, "beatOffsetSeconds": 0.0},
            "steady ({})".format(" | ".join(reasons)))


# A beat-map window (16 beats) whose held-out coverage is under this, or that has too few attacks
# to score at all (the drums stop), is kept out of the 30-minute loop. 0.5, not the beat map's own
# 0.6: every real problem measured on 2026-11-23 was drumless (no hits, 0.0) or the Plain Loop VIII
# 2:14 stretch (0.57, since cut off), while sound windows moved between 0.60 and 0.63 when only
# the song's ending changed (VIII 77 s: 0.627 -> 0.599).
LOOSE_WINDOW_COVERAGE = 0.5


def beat_map_avoid_ranges(beats: Optional[Dict[str, Any]]) -> List[List[float]]:
    """[start, end] seconds of the beat map's loose or drumless windows (detail.windows rows are
    [start, attacks, coverage or None])."""
    windows = (((beats or {}).get("detail") or {}).get("windows")) or []
    ranges = []
    for index, window in enumerate(windows):
        start, coverage = float(window[0]), window[2]
        if index + 1 < len(windows):
            end = float(windows[index + 1][0])
        else:
            end = start + (start - float(windows[index - 1][0]) if index > 0 else 10.0)
        if coverage is None or coverage < LOOSE_WINDOW_COVERAGE:
            ranges.append([round(start, 2), round(end, 2)])
    return ranges


def loop_for(item: Dict[str, Any], measured: Dict[str, Any], digest: str, library: Path,
             force: bool, beats: Optional[Dict[str, Any]] = None) -> Tuple[Dict[str, Any], str]:
    """Loop fields for the entry, from analysis/<id>.loop.json when its inputs still match. The
    loop stays clear of silences, breaks and the beat map's loose or drumless stretches; if no loop
    can, it falls back to the version 1 rule (dropouts only) and says so in detail.fallback."""
    flagged = [flag["atSeconds"] for flag in item["flags"] if flag["atSeconds"] is not None]
    inputs = {"version": loop_points.LOOP_VERSION, "sha256": digest, "bpm": measured["bpm"],
              "beatOffsetSeconds": measured["beatOffsetSeconds"], "avoidAfterSeconds": min(flagged) if flagged else None,
              "avoidRanges": beat_map_avoid_ranges(beats),
              "code": audio_review.sha256(SCRIPTS / "loop_points.py")}
    cache = library / "analysis" / (item["id"] + ".loop.json")
    if not force and cache.is_file():
        try:
            previous = json.loads(cache.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            previous = None
        if isinstance(previous, dict) and previous.get("inputs") == inputs and isinstance(previous.get("result"), dict):
            result = {key: previous["result"].get(key) for key in LOOP_KEYS}
            return result, "reused" + ("" if result["loopStartSeconds"] is not None else " (none)")
    try:
        found = loop_points.analyze_loop(item["sourcePath"], measured["bpm"], measured["beatOffsetSeconds"],
                                         inputs["avoidAfterSeconds"], [tuple(r) for r in inputs["avoidRanges"]], True)
        if found["loopStartSeconds"] is None:
            strict_reason = found["detail"].get("reason")
            found = loop_points.analyze_loop(item["sourcePath"], measured["bpm"], measured["beatOffsetSeconds"],
                                             inputs["avoidAfterSeconds"], None, False)
            found["detail"]["fallback"] = "no loop clear of breaks ({}); dropouts-only rule".format(strict_reason)
        detail = found["detail"]
    except Exception as error:  # a track without loop points still plays once
        found = {key: None for key in LOOP_KEYS}
        detail = {"version": loop_points.LOOP_VERSION, "reason": "analysis failed: {}: {}".format(type(error).__name__, error)}
    result = {key: found.get(key) for key in LOOP_KEYS}
    audio_review.write_json(cache, {"id": item["id"], "analyzedAt": utc_now(), "inputs": inputs,
                                    "result": result, "detail": detail})
    return result, "analyzed" + ("" if result["loopStartSeconds"] is not None else " (none: {})".format(detail.get("reason")))


def clone_or_copy(source: Path, destination: Path, digest: str) -> str:
    partial = destination.with_name("." + destination.name + ".partial")
    partial.unlink(missing_ok=True)
    method = "cp -c"
    completed = subprocess.run(["/bin/cp", "-c", str(source), str(partial)], capture_output=True, text=True)
    if completed.returncode:
        partial.unlink(missing_ok=True)
        shutil.copyfile(source, partial)
        method = "copy (cp -c failed: {})".format(completed.stderr.strip()[:120])
    if audio_review.sha256(partial) != digest:
        partial.unlink(missing_ok=True)
        raise ValueError("copied file hash does not match the source")
    os.replace(partial, destination)
    return method


def build_entry(item: Dict[str, Any], library: Path, previous: Optional[Dict[str, Any]], force: bool,
                reports: Callable[[], Dict[str, Path]], tracks: List[Dict[str, Any]]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    source = item["sourcePath"]
    digest = audio_review.sha256(source)
    relative_file = "tracks/{}{}".format(item["id"], item["suffix"])
    destination = library / relative_file
    row = {"id": item["id"], "failures": None}
    detail = None if force else stored_analysis(library, item["id"], digest)
    if detail is not None:
        measured = measured_from(detail)
        row["analysis"] = "reused"
    else:
        measured, detail = analyze(source, digest, reports())
        detail["id"] = item["id"]
        audio_review.write_json(library / "analysis" / (item["id"] + ".json"), detail)
        row["analysis"] = "existing report" if detail["beatGrid"]["origin"]["kind"] != "freshAnalysis" else "analyzed"
        row["failures"] = detail["beatGrid"]["failures"]
    if destination.is_file() and audio_review.sha256(destination) == digest:
        row["copy"] = "kept"
    else:
        row["copy"] = clone_or_copy(source, destination, digest)
    old_file = (previous or {}).get("file")
    if isinstance(old_file, str) and old_file != relative_file:
        old_path = library / old_file
        still_used = any(track.get("file") == old_file for track in tracks
                         if isinstance(track, dict) and track.get("id") != item["id"])
        if old_path.parent.resolve() == (library / "tracks").resolve() and old_path.is_file() and not still_used:
            old_path.unlink()
    gain, capped = playback_gain(measured["integratedLufs"], measured["truePeakDbtp"])
    beats, beats_note = beat_map_for(item, measured, digest, library, force)
    pulse, row["pulse"] = pulse_plan(measured, detail["beatGrid"]["failures"], beats, beats_note)
    row["beats"] = beats
    loop, row["loop"] = loop_for(item, measured, digest, library, force, beats)
    cover, cover_palette = cover_for(item, library)
    for flag in item["flags"]:
        if flag["atSeconds"] is not None and measured["durationSeconds"] and flag["atSeconds"] > measured["durationSeconds"]:
            print("  warning: {} flag '{}' is after the end of the track".format(item["id"], flag["code"]), flush=True)
    entry = {
        "id": item["id"], "title": item["title"], "genre": item["genre"], "file": relative_file,
        "durationSeconds": measured["durationSeconds"], "sampleRate": measured["sampleRate"],
        "channels": measured["channels"], "integratedLufs": measured["integratedLufs"],
        "truePeakDbtp": measured["truePeakDbtp"], "gainDb": gain, "gainCapped": capped,
        "bpm": measured["bpm"], "beatOffsetSeconds": pulse["beatOffsetSeconds"],
        "gridVerified": measured["gridVerified"], "gridMedianResidualMs": measured["gridMedianResidualMs"],
        "gridP95ResidualMs": measured["gridP95ResidualMs"], "pulseMode": pulse["pulseMode"],
        "modulationHz": pulse["modulationHz"],
        "loopStartSeconds": loop["loopStartSeconds"], "loopEndSeconds": loop["loopEndSeconds"],
        "loopBars": loop["loopBars"], "loopSeamCorrelation": loop["loopSeamCorrelation"],
        "palette": item["palette"] or cover_palette or palette_for(item["id"]), "status": item["status"], "flags": item["flags"], "source": item["source"],
        "sha256": digest, "addedAt": (previous or {}).get("addedAt") or utc_now(),
    }
    if item["about"]:
        entry["about"] = item["about"]
    if cover:
        entry["cover"] = cover
    if pulse["pulseMode"] == "follow":
        entry["pulseCyclesPerBeat"] = pulse["pulseCyclesPerBeat"]
        entry["beatTimes"] = pulse["beatTimes"]
    return entry, row


def fmt(value: Any, pattern: str = "{}") -> str:
    return "null" if value is None else pattern.format(value)


def pulse_cycles_at(entry: Dict[str, Any], seconds: float) -> Optional[float]:
    """The app's pulse phase (cycles) at a file time: grid and steady f * (t - offset); follow
    c * (k + (t - b_k) / (b_{k+1} - b_k)), the first and last intervals carried on outside."""
    if entry.get("pulseMode") == "follow":
        beats, cycles = entry["beatTimes"], entry["pulseCyclesPerBeat"]
        k = min(max(bisect.bisect_right(beats, seconds) - 1, 0), len(beats) - 2)
        return cycles * (k + (seconds - beats[k]) / (beats[k + 1] - beats[k]))
    if entry.get("modulationHz") is None:
        return None
    return entry["modulationHz"] * (seconds - entry["beatOffsetSeconds"])


def print_pulse_table(rows: List[Tuple[Dict[str, Any], Dict[str, Any]]]) -> None:
    """Pulse plan per track with the beat map's measurements (strong low-band attacks of
    verify_beat_grid, weight >= beat_map.STRONG_WEIGHT): share within 30 ms of the map's beats or
    half-beats and median distance (held out), the same share for the best single global grid,
    16-beat windows that line up, the map's agreement with the grid (grid tracks), and the pulse
    phase step at the loop seam (ms at the pulse rate)."""
    print("{:<24} {:<7} {:<8} {:>8} {:>3} {:>6} {:>13} {:>6} {:>7} {:>3} {:>11} {:>6}".format(
        "id", "pulse", "grid", "Hz", "c", "beats", "map cov/med", "grid", "windows", "L", "agree ms", "seam"))
    for row, entry in rows:
        result = ((row.get("beats") or {}).get("result")) or {}
        quality = (row.get("beats") or {}).get("quality") or {}
        held, grid = quality.get("heldOut") or {}, quality.get("bestGlobalGrid") or {}
        agreement = (row.get("beats") or {}).get("gridAgreement") or {}
        mode = entry.get("pulseMode")
        cycles = entry.get("pulseCyclesPerBeat")
        if mode == "grid" and entry.get("bpm"):
            cycles = max(1, int(round(MODULATION_TARGET_HZ * 60.0 / entry["bpm"])))
        seam = None
        if entry.get("loopStartSeconds") is not None and entry.get("modulationHz"):
            start, end = pulse_cycles_at(entry, entry["loopStartSeconds"]), pulse_cycles_at(entry, entry["loopEndSeconds"])
            if start is not None and end is not None:
                seam = ((end - start + 0.5) % 1.0 - 0.5) / entry["modulationHz"] * 1000
        print("{:<24} {:<7} {:<8} {:>8} {:>3} {:>6} {:>13} {:>6} {:>7} {:>3} {:>11} {:>6}".format(
            entry["id"], mode, "pass" if entry["gridVerified"] else ("relaxed" if mode == "grid" else "fail"),
            fmt(entry.get("modulationHz"), "{:.4f}"), fmt(cycles), fmt(len(entry["beatTimes"]) if mode == "follow" else None),
            "{}/{}".format(fmt(held.get("coverage30ms"), "{:.3f}"), fmt(held.get("medianResidualMs"), "{:.2f}")),
            fmt(grid.get("coverage30ms"), "{:.3f}"),
            "{}/{}".format(fmt(quality.get("supportedWindows")), fmt(quality.get("scorableWindows"))),
            fmt(quality.get("smoothingBeats")),
            "{}/{}".format(fmt(agreement.get("medianAbsoluteDifferenceMs"), "{:.1f}"), fmt(agreement.get("p95AbsoluteDifferenceMs"), "{:.1f}"))
            if mode == "grid" else "-",
            fmt(seam, "{:+.1f}")))
        if mode != "follow" and result and not result.get("accepted") and mode == "steady":
            print("{:<24} beat map refused: {}".format("", "; ".join(result.get("failures") or [])))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--library", type=Path, required=True, help="library folder (created if missing)")
    parser.add_argument("--sources", type=Path, required=True, help="JSON list of source tracks")
    parser.add_argument("--force-reanalyze", action="store_true", help="measure every source again")
    args = parser.parse_args()
    library = args.library.expanduser().resolve()
    audio_root = (PROJECT / "Audio").resolve()
    if library == audio_root or audio_root in library.parents:
        parser.error("--library must not be inside " + str(audio_root))
    try:
        sources = load_sources(args.sources.expanduser(), library)
    except (OSError, ValueError) as error:
        parser.error(str(error))

    library_file = library / "library.json"
    document = {"version": LIBRARY_VERSION, "updatedAt": None, "tracks": []}
    if library_file.exists():
        document = json.loads(library_file.read_text(encoding="utf-8"))
        if not isinstance(document, dict) or document.get("version") != LIBRARY_VERSION \
                or not isinstance(document.get("tracks"), list):
            parser.error("{} is not a version {} library; refusing to overwrite".format(library_file, LIBRARY_VERSION))
    tracks = list(document["tracks"])
    position = {track.get("id"): index for index, track in enumerate(tracks) if isinstance(track, dict)}
    (library / "tracks").mkdir(parents=True, exist_ok=True)
    (library / "analysis").mkdir(exist_ok=True)

    cache: Dict[str, Dict[str, Path]] = {}

    def reports() -> Dict[str, Path]:
        if "found" not in cache:
            cache["found"] = existing_grid_reports()
        return cache["found"]

    rows, failures = [], []
    for item in sources:
        print("[{}] {}".format(item["id"], item["sourcePath"]), flush=True)
        index = position.get(item["id"])
        previous = tracks[index] if index is not None else None
        try:
            entry, row = build_entry(item, library, previous, args.force_reanalyze, reports, tracks)
        except Exception as error:  # one bad file must not block the others
            failures.append({"id": item["id"], "error": "{}: {}".format(type(error).__name__, error)})
            print("  ERROR: " + failures[-1]["error"], file=sys.stderr, flush=True)
            continue
        row["action"] = "added" if previous is None else ("unchanged" if entry == previous else "updated")
        if index is None:
            position[item["id"]] = len(tracks)
            tracks.append(entry)
        else:
            tracks[index] = entry
        rows.append((row, entry))
        print("  {action}; analysis {analysis}; copy {copy}; pulse: {pulse}; loop: {loop}".format(**row), flush=True)
        if row["failures"]:
            print("  grid failures: " + "; ".join(row["failures"]), flush=True)

    if tracks == document["tracks"] and library_file.exists():
        print("library.json unchanged; not rewritten: " + str(library_file))
    else:
        audio_review.write_json(library_file, {"version": LIBRARY_VERSION, "updatedAt": utc_now(), "tracks": tracks})
        print("library.json written ({} tracks): {}".format(len(tracks), library_file))

    header = "{:<24} {:>7} {:>6} {:>6} {:>4} {:>9} {:>7} {:>5} {:>13} {:>8}".format(
        "id", "LUFS", "TP", "gain", "cap", "BPM", "offset", "grid", "med/p95 ms", "modHz")
    print(header)
    for row, entry in rows:
        print("{:<24} {:>7} {:>6} {:>6} {:>4} {:>9} {:>7} {:>5} {:>13} {:>8}".format(
            entry["id"], fmt(entry["integratedLufs"], "{:.2f}"), fmt(entry["truePeakDbtp"], "{:.2f}"),
            fmt(entry["gainDb"], "{:.2f}"), "yes" if entry["gainCapped"] else "no", fmt(entry["bpm"], "{:.4f}"),
            fmt(entry["beatOffsetSeconds"], "{:.4f}"), "pass" if entry["gridVerified"] else "fail",
            "{}/{}".format(fmt(entry["gridMedianResidualMs"], "{:.2f}"), fmt(entry["gridP95ResidualMs"], "{:.2f}")),
            fmt(entry["modulationHz"], "{:.4f}")))
    print_pulse_table(rows)
    print("{:<24} {:>10} {:>10} {:>8} {:>5} {:>6}".format("id", "loopStart", "loopEnd", "length", "bars", "r"))
    for row, entry in rows:
        if entry["loopStartSeconds"] is None:
            print("{:<24} {}".format(entry["id"], "no loop: plays once"))
            continue
        print("{:<24} {:>10.3f} {:>10.3f} {:>7.1f}s {:>5} {:>6.2f}".format(
            entry["id"], entry["loopStartSeconds"], entry["loopEndSeconds"],
            entry["loopEndSeconds"] - entry["loopStartSeconds"], entry["loopBars"], entry["loopSeamCorrelation"]))
    for failure in failures:
        print("FAILED {id}: {error}".format(**failure), file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
