"""Generate median and nearest-rank P95 from the archived device samples."""
import json
import math
from pathlib import Path
from statistics import median

directory = Path(__file__).resolve().parent / "results"
modes = ["production", "direct", "generic-kotlin", "generic-native", "fixed-kotlin", "fixed-native", "fixed-direct"]
summary = {}
for name in ["main", "performance", "socket"]:
    report = json.loads((directory / (name + ".json")).read_text())
    section = {}
    for mode in sorted({r["mode"] for r in report["samples"]}):
        rows = [r for r in report["samples"] if r["round"] >= 0 and r["mode"] == mode]
        key = "responseMs" if name == "socket" else "totalMs"
        times = sorted(r[key] for r in rows)
        stats = dict(n=len(rows), medianMs=round(median(times), 2), p95Ms=round(times[math.ceil(.95 * len(times)) - 1], 2))
        if name == "socket":
            stats["collectMedianMs"] = round(median(r["collectMs"] for r in rows), 2)
        elif mode in [2, 3, 4, 5]:
            stats["packMedianMs"] = round(median(r["packMs"] for r in rows), 2)
            stats["replayMedianMs"] = round(median(r["totalMs"] - r["packMs"] for r in rows), 2)
        section[modes[mode]] = stats
    summary[name] = section
print(json.dumps(summary, ensure_ascii=False, indent=2))
