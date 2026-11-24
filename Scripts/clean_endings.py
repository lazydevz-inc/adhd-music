#!/usr/bin/env python3
"""Trim each song's ending when the part after its 30-minute loop has a problem.

After the last loop pass the app plays the file on from loopEnd to its natural end, once in
every 30-minute play. When that stretch has a silence (0.25 s or more), a break of 5 s or more
(loop_points.breaks), a loose or drumless beat-map window (build_library.beat_map_avoid_ranges)
or trailing silence of 2.5 s or more, the song is cut two bars after loopEnd (never past the first
problem) with a one-bar fade (trim_song_end.trim_end) into Audio/Prepared/clean-end/<id>/, and
Scripts/library-sources.json points at that copy. The last ENDING_ZONE_SECONDS are the song's own
ending (its fade-out); only trailing silence counts there.

    .venv-audio/bin/python Scripts/clean_endings.py --library <Library folder>          # report
    .venv-audio/bin/python Scripts/clean_endings.py --library <Library folder> --apply  # trim

Run Scripts/build_library.py afterwards so loops, beat maps and the catalog follow the new files.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

SCRIPTS = Path(__file__).resolve().parent
PROJECT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

import build_library  # noqa: E402  beat_map_avoid_ranges
import loop_points  # noqa: E402  loudness_curves, breaks
import trim_song_end  # noqa: E402  trim_end

TRAILING_SILENCE_SECONDS = 2.5
ENDING_ZONE_SECONDS = 15.0
BARS_AFTER_LOOP = 2


def outro_problems(source: Path, loop_end: float, beats: dict) -> list:
    """(start, end, kind) problems after the loop end, ignoring the file's own final fade."""
    audio, rate = sf.read(str(source), dtype="float64", always_2d=True)
    duration = len(audio) / rate
    short_term, _ = loop_points.loudness_curves(audio, rate)
    middle = short_term[int(0.2 * len(short_term)):int(0.8 * len(short_term))]
    body = float(np.median(middle))
    reached = np.where(short_term >= body - loop_points.BODY_DROP_DB)[0]
    body_range = (reached[0] * loop_points.FEATURE_HOP, (reached[-1] + 1) * loop_points.FEATURE_HOP)
    found = loop_points.breaks(audio, rate, short_term, body, body_range)
    found += [(a, b, "loose beat") for a, b in build_library.beat_map_avoid_ranges(beats)]
    start = loop_end + loop_points.SEAM_SECONDS / 2
    problems = []
    for a, b, kind in sorted(found):
        if b <= start:
            continue
        touches_end = b >= duration - 0.2
        if touches_end and kind == "silence":
            if b - a >= TRAILING_SILENCE_SECONDS:
                problems.append((max(a, start), b, "trailing silence"))
            continue
        if a >= duration - ENDING_ZONE_SECONDS or (touches_end and kind == "drop"):
            continue  # the song's own ending
        problems.append((max(a, start), b, kind))
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--sources", type=Path, default=SCRIPTS / "library-sources.json")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    catalog = json.loads((args.library / "library.json").read_text())
    sources = json.loads(args.sources.read_text())
    by_id = {track["id"]: track for track in catalog["tracks"]}
    changed = 0
    for entry in sources["tracks"]:
        track = by_id.get(entry["id"])
        if not track or track.get("loopEndSeconds") is None or not track.get("loopBars"):
            print("{:24} no loop, skipped".format(entry["id"]))
            continue
        source = (PROJECT / entry["path"]).resolve()
        beats_file = args.library / "analysis" / (entry["id"] + ".beats.json")
        beats = json.loads(beats_file.read_text()) if beats_file.is_file() else {}
        loop_start, loop_end = track["loopStartSeconds"], track["loopEndSeconds"]
        problems = outro_problems(source, loop_end, beats)
        if not problems:
            print("{:24} ending clean (loop ends {:.1f} s of {:.1f} s)".format(entry["id"], loop_end, track["durationSeconds"]))
            continue
        bar = (loop_end - loop_start) / track["loopBars"]
        before = min(loop_end + BARS_AFTER_LOOP * bar + 0.1, problems[0][0] - 0.05)
        summary = ", ".join("{} {:.1f}-{:.1f} s".format(kind, a, b) for a, b, kind in problems[:8])
        if len(problems) > 8:
            summary += ", and {} more".format(len(problems) - 8)
        print("{:24} trim after {:.1f} s: {}".format(entry["id"], before, summary))
        if not args.apply:
            continue
        output = PROJECT / "Audio" / "Prepared" / "clean-end" / entry["id"] / (source.stem.replace("-end", "") + "-end.flac")
        why = ("After the 30-minute loop ({:.2f}-{:.2f} s) the file played on into: {}. That part plays once at the "
               "end of every 30-minute play, so the song now ends two bars after the loop with a one-bar fade."
               .format(loop_start, loop_end, summary))
        provenance = trim_song_end.trim_end(source, output, before, bar, loop_end, why)
        entry["path"] = str(output.relative_to(PROJECT))
        note = "Ending trimmed 2026-11-23 (Scripts/clean_endings.py): kept 0-{:.2f} s with a one-bar fade; {}. Provenance: {}." \
            .format(provenance["kept"]["endSeconds"], summary, str((output.parent / "provenance.json").relative_to(PROJECT)))
        entry["notes"] = (entry.get("notes", "") + " " + note).strip()
        changed += 1
    if args.apply and changed:
        args.sources.write_text(json.dumps(sources, ensure_ascii=False, indent=1) + "\n")
    print("{} {} song(s)".format("trimmed" if args.apply else "would trim", changed if args.apply else "the listed"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
