#!/usr/bin/env python3
"""Serial, paced A/B CPU-work comparison; never an estimate of battery watts.

Use the same executable/model weights with two model directories whose only
runtime difference is cpu-runtime.conf. Two repeats use A/B/B/A ordering.
Audio, full events, and transcripts remain in the chosen local report folder.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--baseline-model", type=Path, required=True)
    parser.add_argument("--candidate-model", type=Path, required=True)
    parser.add_argument("--terms", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--repeats", type=int, choices=(1, 2), default=2)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("vocabulary_metrics", Path(__file__).with_name("vocabulary-metrics.py"))
    metrics = importlib.util.module_from_spec(spec); spec.loader.exec_module(metrics)
    args.out.mkdir(parents=True, exist_ok=False)
    reference = args.reference.read_text() if args.reference else None
    order = ["baseline", "sleep"] if args.repeats == 1 else ["baseline", "sleep", "sleep", "baseline"]
    models = {"baseline": args.baseline_model, "sleep": args.candidate_model}
    counts = {"baseline": 0, "sleep": 0}; runs = []
    for mode in order:
        counts[mode] += 1
        name = f"{mode}-{counts[mode]}"
        report = args.out / f"{name}.json"
        command = [str(args.binary), "--benchmark", "--input", str(args.input), "--report", str(report),
                   "--model", str(models[mode]), "--enhance", "--terms", str(args.terms), "--paths", "2", "--score", "0.5"]
        with (args.out / f"{name}.log").open("w") as log:
            completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        data = json.loads(report.read_text())
        if data["errors"] or not data["enhancementActive"] or data.get("cpuWaitingMode") != ("default" if mode == "baseline" else "sleep"):
            raise RuntimeError(f"{name}: runtime failure or wrong configuration; inspect {report}")
        if completed.returncode and not (reference is None and not data["sampleCount"] and completed.returncode == 1):
            raise RuntimeError(f"{name}: benchmark exited {completed.returncode}")
        run = {"name": name, "mode": mode, "cpuSeconds": data["activeCPUSeconds"], "wallSeconds": data["activeWallSeconds"],
               "maximumSeconds": data["maximumSeconds"], "overThree": data["overThreeSeconds"],
               "maximumQueueSeconds": data["maximumQueueWaitSeconds"], "maximumProcessingSeconds": data["maximumProcessingSeconds"],
               "errors": data["errors"], "sampleCount": data["sampleCount"]}
        run["singleCorePercent"] = 100 * run["cpuSeconds"] / run["wallSeconds"]
        if reference is not None: run["accuracy"] = metrics.metrics(reference, data)
        runs.append(run); print(json.dumps(run, sort_keys=True), flush=True)
    averages = {mode: statistics.mean(r["cpuSeconds"] for r in runs if r["mode"] == mode) for mode in models}
    result = {"method": "Serial real-time input; process user+system CPU time from model-ready to finish/release. Excludes model initialization. CPU seconds measure work, not watts or battery-life gain. Native timestamps estimate latency; omitted words counted separately against reference.",
              "order": order, "runs": runs, "meanCPUSeconds": averages,
              "cpuWorkReductionFraction": 1 - averages["sleep"] / averages["baseline"]}
    (args.out / "summary.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
