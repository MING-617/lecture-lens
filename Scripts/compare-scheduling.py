#!/usr/bin/env python3
"""Serial, paced recognition comparisons on Apple Silicon.

CPU energy is the kernel's per-task CPU energy counter (nanojoules), not
whole-app/whole-machine battery use. Model initialization is excluded.
Keep raw audio, words and event reports local; publish only summary metrics.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess

PROFILES = {
    "baseline": (2, "userInitiated"),
    "single": (1, "userInitiated"),
    "utility": (1, "utility"),
    "background": (1, "background"),
    "two_background": (2, "background"),
    "two_utility": (2, "utility"),
}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--binary", type=Path, required=True)
    p.add_argument("--model", type=Path, required=True)
    p.add_argument("--terms", type=Path, required=True)
    p.add_argument("--input", type=Path, required=True)
    p.add_argument("--reference", type=Path)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--profiles", nargs="+", choices=PROFILES, default=list(PROFILES))
    args = p.parse_args()
    spec = importlib.util.spec_from_file_location("metrics", Path(__file__).with_name("vocabulary-metrics.py"))
    metrics = importlib.util.module_from_spec(spec); spec.loader.exec_module(metrics)
    args.out.mkdir(parents=True, exist_ok=False)
    reference = args.reference.read_text() if args.reference else None
    runs, counts, transcripts = [], {}, []
    for mode in args.profiles:
        counts[mode] = counts.get(mode, 0) + 1
        name = f"{mode}-{counts[mode]}"
        threads, qos = PROFILES[mode]
        report = args.out / f"{name}.json"
        command = [str(args.binary), "--benchmark", "--input", str(args.input), "--report", str(report),
                   "--model", str(args.model), "--enhance", "--terms", str(args.terms), "--paths", "2", "--score", "0.5",
                   "--threads", str(threads), "--qos", qos, "--provider", "cpu"]
        with (args.out / f"{name}.log").open("w") as log:
            completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
        data = json.loads(report.read_text())
        if not data["enhancementActive"] or data.get("cpuWaitingMode") != "sleep":
            raise RuntimeError(f"{name}: wrong enhancement/runtime configuration")
        accepted = not data["errors"] and (completed.returncode == 0 or (reference is None and not data["sampleCount"] and completed.returncode == 1))
        if (data.get("inferenceThreads"), data.get("requestedSchedulingClass")) != (threads, qos):
            raise RuntimeError(f"{name}: wrong requested configuration")
        run = {"name": name, "profile": mode, "cpuSeconds": data["activeCPUSeconds"], "wallSeconds": data["activeWallSeconds"],
               "cpuEnergyNanojoules": data.get("activeCPUEnergyNanojoules"),
               "performanceCoreFraction": data.get("activePerformanceCoreFraction"),
               "interruptWakeups": data.get("activeInterruptWakeups"),
               "maximumSeconds": data["maximumSeconds"], "overThree": data["overThreeSeconds"],
               "maximumQueueSeconds": data["maximumQueueWaitSeconds"], "maximumProcessingSeconds": data["maximumProcessingSeconds"],
               "sampleCount": data["sampleCount"], "accepted": accepted, "runtimeErrors": data["errors"]}
        run["singleCorePercent"] = 100 * run["cpuSeconds"] / run["wallSeconds"]
        if reference is not None: run["accuracy"] = metrics.metrics(reference, data)
        run["runtimeCompleted"] = accepted
        run["latencyPassed"] = data["overThreeSeconds"] == 0 and run.get("accuracy", {}).get("correctSpellingOverThree", 0) == 0
        run["accepted"] = accepted and run["latencyPassed"]
        runs.append(run); transcripts.append(data["transcript"])
        print(json.dumps(run, sort_keys=True), flush=True)
    means = {mode: {key: statistics.mean(r[key] for r in runs if r["profile"] == mode and r["accepted"])
                    for key in ("cpuSeconds", "cpuEnergyNanojoules", "performanceCoreFraction")
                    if all(r.get(key) is not None for r in runs if r["profile"] == mode)}
             for mode in set(args.profiles) if any(r["profile"] == mode and r["accepted"] for r in runs)}
    result = {"method": __doc__, "order": args.profiles, "runs": runs, "means": means,
              "allFinalTranscriptsIdentical": all(t == transcripts[0] for t in transcripts)}
    if "baseline" in means:
        result["cpuEnergyReductionFraction"] = {mode: 1 - values["cpuEnergyNanojoules"] / means["baseline"]["cpuEnergyNanojoules"]
                                               for mode, values in means.items() if "cpuEnergyNanojoules" in values}
    (args.out / "summary.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
