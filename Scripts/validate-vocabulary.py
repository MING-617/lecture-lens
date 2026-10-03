#!/usr/bin/env python3
"""Reproduce the synthetic vocabulary suite on macOS without recording audio.

All inputs/reports are generated under .cache. Parameter tuning is fast,
simulated timing; use the app's --benchmark for production-paced timing.
"""
import argparse
import array
import importlib.util
import json
import math
from pathlib import Path
import random
import subprocess
import wave


def run(args):
    subprocess.run([str(arg) for arg in args], check=True)


def write_wave(path, samples):
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000)
        output.writeframes(samples.tobytes())


def generate(repository, output):
    fixtures = repository / "Tests/Fixtures/caption-corpus"
    for text in sorted(fixtures.glob("*.txt")):
        (output / text.name).write_text(text.read_text())
    pack = json.loads((repository / "Resources/coursepack.portable.json").read_text())
    parts = []
    for course in pack["courses"]:
        terms = dict.fromkeys(term["english"] for term in pack["terms"] if term["course"] == course["id"])
        parts.append("Here are the vocabulary words for our next class. " + ". ".join("Please note the phrase " + term for term in terms) + ". That is the end of this list.")
    (output / "all-terms-holdout.txt").write_text(" ".join(parts))
    voices = {"tuning": ("Daniel", 175), "holdout": ("Samantha", 175),
              "general": ("Daniel", 175), "independent": ("Samantha", 183),
              "challenge": ("Daniel", 215), "all-terms-holdout": ("Samantha", 185)}
    for name, (voice, rate) in voices.items():
        run(["say", "-v", voice, "-r", rate, "-f", output / (name + ".txt"), "-o", output / (name + ".aiff")])
        run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", output / (name + ".aiff"), output / (name + ".wav")])
    with wave.open(str(output / "tuning.wav")) as source:
        audio = array.array("h", source.readframes(source.getnframes()))
    rms = math.sqrt(sum(sample * sample for sample in audio) / len(audio))
    rng = random.Random(617)
    noise = array.array("h", (max(-32768, min(32767, round(sample + rng.gauss(0, rms / 10 ** (15 / 20))))) for sample in audio))
    write_wave(output / "tuning-noise.wav", noise)
    paused = array.array("h", [0] * 160000)
    pivot = len(audio) // 2
    paused.extend(audio[:pivot]); paused.extend([0] * 240000)
    paused.extend(audio[pivot:]); paused.extend([0] * 160000)
    write_wave(output / "tuning-pauses.wav", paused)
    write_wave(output / "silence.wav", array.array("h", [0] * 480000))
    for name in ["tuning-noise", "tuning-pauses"]:
        (output / (name + ".txt")).write_text((output / "tuning.txt").read_text())
    (output / "silence.txt").write_text("")


if __name__ == "__main__":
    repository = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=repository / ".cache/vocabulary-validation")
    parser.add_argument("--generate-only", action="store_true")
    parser.add_argument("--skip-generation", action="store_true")
    args = parser.parse_args(); output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if not args.skip_generation: generate(repository, output)
    if args.generate_only: raise SystemExit(0)
    vendor = repository / "Vendor/SherpaOnnx"
    probe = output / "probe"
    run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-target", "arm64-apple-macos26.0",
         "-import-objc-header", vendor / "c-api.h", repository / "Sources/Core.swift", repository / "Sources/StreamingDecoder.swift",
         repository / "Tests/VocabularyProbe.swift", "-L", vendor, "-l", "sherpa-onnx-c-api", "-Xlinker", "-rpath", "-Xlinker", vendor, "-o", probe])
    spec = importlib.util.spec_from_file_location("metrics", Path(__file__).with_name("vocabulary-metrics.py"))
    metrics = importlib.util.module_from_spec(spec); spec.loader.exec_module(metrics)
    summary = {"method": "Synthetic speech; fast simulated timing. Not a classroom or microphone guarantee.", "results": {}}
    cases = ["tuning", "holdout", "general", "independent", "challenge", "all-terms-holdout", "tuning-noise", "tuning-pauses", "silence"]
    for name in cases:
        settings = [(0, 0.5), (2, 0.5)]
        if name == "tuning": settings += [(paths, score) for paths in [2, 4] for score in [0.5, 1.0, 1.5] if (paths, score) != (2, 0.5)]
        for paths, score in settings:
            label = f"{name}-{paths}-{score}"
            report = output / (label + ".json")
            run([probe, repository / "Resources/StreamingEnglish", output / (name + ".wav"), report, repository / "Resources/coursepack.portable.json", paths, score])
            summary["results"][label] = metrics.metrics((output / (name + ".txt")).read_text(), json.loads(report.read_text()))
            (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print("Accuracy and timing summary:", output / "summary.json")
