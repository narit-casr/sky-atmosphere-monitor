#!/usr/bin/env python3
"""Health check for one copy of the Activity 1 platform (standard library only).

  python3 platform_health.py <root> [--label NAME] [--quiet]

<root> is the platform folder (the HPC copy's .../NARITForecastingSystem/dashboard, or the
Seagate drive's .../TSRI_ST_71/Activity1_Platform), so the same script checks either copy:
it runs with the HPC environment's Python or the workstation's own python3.

Checks
  data age   newest observation time inside each dashboard file, with the "late" and
             "stale" limits of the page's status panel (index.html), plus the radar
             frames, the forecast run, the correction and the season-outlook log
  errors     ERROR lines in each download log over the last ERROR_WINDOW_H hours
Prints a table and exits 1 when anything is stale or failing. With --quiet it prints
only then, so from cron (which mails a job's output) you get a mail only on problems.
"""
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ERROR_WINDOW_H = 3
# label | dashboard file | how to read its newest time | late h | stale h
DATA = [
    ("Air quality (PCD)", "dashboard.json", ("stations", "PM25_time"), 5, 8),
    ("Weather stations (TMD)", "met_obs.json", ("stations", "TEMP_time"), 3, 5),
    ("Observatory weather (NARIT)", "astro_obs.json", ("stations", "ATEMP_time"), 3, 5),
    ("LiDAR PBL height", "lidar_obs.json", ("stations", "PBLH_time"), 3, 5),
    ("Fire hotspots (FIRMS, UTC)", "dashboard.json", ("hotspots", "t"), 12, 24),
    ("Radar composite (TMD)", "radar.json", ("frames", "time_local"), 1, 3),
    ("WRF-Chem forecast run", "forecast_stations.json", ("init_local",), 36, 60),
    ("Forecast correction", "forecast_correction.json", ("generated_local",), 2, 4),
    ("Dashboard export", "dashboard.json", ("generated_local",), 2, 4),
]
LOGS = ["PCD_AllStations_Archive/download_log.txt", "TMD_AWS_Archive/download_log.txt",
        "NARIT_Obs_Archive/download_log.txt", "LIDAR_PBL/download_log.txt", "FIRMS_Archive/download_log.txt",
        "RADAR/TMD/download_log.txt", "WRF_Forecast/download_log.txt"]
HAZE_LOG = "HazeTracker/haze_tracker_log_SEAsia.csv"
TIME_FORMATS = ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%d-%b-%Y %H:%M:%S")


def parse_t(s):
    for fmt in TIME_FORMATS:
        try:
            return datetime.strptime(str(s).strip(), fmt)
        except ValueError:
            pass
    return None


def as_list(x):
    return x if isinstance(x, list) else ([] if x is None else [x])


def newest(J, path):
    if len(path) == 1:
        return parse_t(J.get(path[0], ""))
    times = []
    group = J.get(path[0])
    if isinstance(group, dict):                                   # hotspots: parallel arrays
        times = [parse_t(t) for t in as_list(group.get(path[1]))]
    else:
        times = [parse_t(r.get(path[1], "")) for r in as_list(group) if isinstance(r, dict)]
    times = [t for t in times if t]
    return max(times) if times else None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    root = Path(args[0])
    label = sys.argv[sys.argv.index("--label") + 1] if "--label" in sys.argv else str(root)
    quiet = "--quiet" in sys.argv
    dash = root / "dashboard" / "dashboard_data"
    now = datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(hours=7)   # Bangkok time, any machine zone
    rows, problems = [], 0

    for name, fname, path, late, stale in DATA:
        f = dash / fname
        if not f.exists():
            rows.append((name, "MISSING", f"{fname} not found"))
            problems += 1
            continue
        try:
            J = json.loads(f.read_text(encoding="utf-8"))
        except ValueError as e:
            rows.append((name, "ERROR", f"{fname} unreadable ({e})"))
            problems += 1
            continue
        t = newest(J, path)
        ref = now - timedelta(hours=7) if "UTC" in name else now
        if t is None:
            rows.append((name, "STALE", "no time found"))
            problems += 1
            continue
        age = (ref - t).total_seconds() / 3600
        state = "OK" if age <= late else ("LATE" if age <= stale else "STALE")
        problems += state == "STALE"
        rows.append((name, state, f"newest {t:%d %b %H:%M} ({age:.1f} h ago)"))

    hz = root / HAZE_LOG
    if hz.exists():
        last = [l for l in hz.read_text(encoding="utf-8").splitlines()[1:] if l.strip()]
        t = parse_t(last[-1].split(",")[0] + " 00:00") if last else None
        age_d = (now - t).days if t else None
        state = "OK" if age_d is not None and age_d <= 8 else "STALE"
        problems += state == "STALE"
        rows.append(("Season outlook (haze tracker)", state, f"last run {t:%d %b}" if t else "log empty"))
    else:
        rows.append(("Season outlook (haze tracker)", "MISSING", "log not found"))
        problems += 1

    since = now - timedelta(hours=ERROR_WINDOW_H)
    for rel in LOGS:
        f = root / rel
        if not f.exists():
            continue
        with open(f, "rb") as fh:                                 # only the end of the log
            fh.seek(0, 2)
            fh.seek(max(0, fh.tell() - 200_000))
            tail = fh.read().decode("utf-8", errors="replace").splitlines()
        errs = [l for l in tail if "| ERROR |" in l and (parse_t(l.split(" | ")[0]) or datetime.min) >= since]
        if errs:
            problems += 1
            rows.append((rel.split("/")[0], f"{len(errs)} ERROR(S)", errs[-1].split("| ERROR |")[-1].strip()[:90]))

    if quiet and not problems:
        return 0
    print(f"Platform health -- {label} -- {now:%Y-%m-%d %H:%M}")
    w = max(len(r[0]) for r in rows)
    for name, state, detail in rows:
        print(f"  {name:<{w}s}  {state:<10s} {detail}")
    print(f"  -> {problems} problem(s)" if problems else "  -> all OK")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
