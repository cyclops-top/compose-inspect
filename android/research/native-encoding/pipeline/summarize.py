"""Summarize warmed per-mode measurements. P95 uses nearest rank."""
import json
import math
from pathlib import Path
from statistics import median

root = Path(__file__).resolve().parent / "results"
summary = {}
for scene in ("cards", "texture", "framing/cards", "framing/texture"):
    data = json.loads((root / (scene + ".json")).read_text())
    scene_rows = [r for r in data["samples"] if r["round"] >= 0]
    result = {}
    for mode in dict.fromkeys(r["mode"] for r in scene_rows):
        rows = [r for r in scene_rows if r["mode"] == mode]
        assert len(rows) == 24 and len({r["pid"] for r in rows}) == 1
        record = {k: round(median(r[k] for r in rows), 2) for k in
                  ["responseMs", "collectMs", "treeMs", "copyMs", "pngMs", "waitPngMs",
                   "packMs", "encodeMs", "frameMs", "writeMs", "imageBytes", "wireBytes"]}
        record["p95Ms"] = round(sorted(r["responseMs"] for r in rows)[math.ceil(len(rows)*.95)-1], 2)
        result[mode] = record
    summary[scene] = result
tree = json.loads((root / "tree.json").read_text())
matrix = {}
for phase, mode in dict.fromkeys((r["phase"], r["mode"]) for r in tree):
    rows = [r for r in tree if r["phase"] == phase and r["mode"] == mode and r["round"] >= 0]
    matrix[phase + "/" + mode] = {k: round(median(r[k] for r in rows), 2)
                                  for k in ("responseMs", "collectMs", "signatureMs")}
summary["tree"] = matrix
index = json.loads((root / "index.json").read_text())
summary["index"] = {label: {key: round(median(r[key] for r in index["samples"] if r["label"] == label), 2)
                            for key in ("responseMs", "signatureMs", "collectMs")}
                    for label in dict.fromkeys(r["label"] for r in index["samples"])}
print(json.dumps(summary, indent=2))
