"""Copies the music library into a folder the shared build ships in Contents/Resources/Library.

Reads the real library (never writes to it), keeps only what the app reads:
  - tracks: FLAC copied as is; WAV turned into FLAC sample for sample (checked after writing)
  - covers
  - library.json without personal fields (source paths, Suno song ids, hashes); every song
    starts in the mix without the New tag, since the whole library is new to the person.

Usage: python bundle_library.py --library <real Library dir> --out <cache dir>
Files already converted are reused when the source is older than the copy.
"""
import argparse
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

DROP_KEYS = {"source", "sha256"}


def convert_wav(src: Path, dst: Path) -> None:
    info = sf.info(str(src))
    subtype = {"PCM_16": "PCM_16", "PCM_24": "PCM_24"}.get(info.subtype)
    if subtype is None:
        raise SystemExit(f"{src.name}: {info.subtype} WAV can't go to FLAC without changing samples")
    data, rate = sf.read(str(src), dtype="int32", always_2d=True)
    tmp = dst.with_suffix(".tmp.flac")
    sf.write(str(tmp), data, rate, subtype=subtype, format="FLAC")
    back, rate_back = sf.read(str(tmp), dtype="int32", always_2d=True)
    if rate_back != rate or back.shape != data.shape or not np.array_equal(back, data):
        tmp.unlink(missing_ok=True)
        raise SystemExit(f"{src.name}: FLAC copy is not sample-identical")
    tmp.replace(dst)


def fresh(src: Path, dst: Path) -> bool:
    return dst.exists() and dst.stat().st_mtime >= src.stat().st_mtime


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--library", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    catalog = json.loads((args.library / "library.json").read_text())
    (args.out / "tracks").mkdir(parents=True, exist_ok=True)
    (args.out / "covers").mkdir(parents=True, exist_ok=True)

    keep_tracks, keep_covers, tracks = set(), set(), []
    for item in catalog["tracks"]:
        src = args.library / item["file"]
        if not src.exists():
            raise SystemExit(f"missing track {src}")
        rel = Path(item["file"])
        if src.suffix.lower() == ".wav":
            rel = rel.with_suffix(".flac")
            dst = args.out / rel
            if not fresh(src, dst):
                print(f"  FLAC {src.name}", file=sys.stderr)
                convert_wav(src, dst)
        else:
            dst = args.out / rel
            if not fresh(src, dst):
                shutil.copy2(src, dst)
        keep_tracks.add(dst.name)

        clean = {k: v for k, v in item.items() if k not in DROP_KEYS}
        clean["file"] = rel.as_posix()
        clean["status"] = "inMix"
        cover = item.get("cover")
        if cover:
            csrc, cdst = args.library / cover, args.out / cover
            if csrc.exists():
                if not fresh(csrc, cdst):
                    shutil.copy2(csrc, cdst)
                keep_covers.add(cdst.name)
            else:
                clean.pop("cover", None)
        tracks.append(clean)

    for folder, keep in (("tracks", keep_tracks), ("covers", keep_covers)):
        for f in (args.out / folder).iterdir():
            if f.name not in keep:
                f.unlink()

    out = dict(catalog)
    out["tracks"] = tracks
    (args.out / "library.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    text = (args.out / "library.json").read_text()
    if "/Users/" in text or "songId" in text:
        raise SystemExit("personal fields left in the shared catalog")
    size = sum(f.stat().st_size for f in args.out.rglob("*") if f.is_file())
    print(f"{len(tracks)} songs, {size / 1e6:.0f} MB → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
