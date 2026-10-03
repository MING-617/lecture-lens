#!/usr/bin/env python3
"""Reference-text accuracy and correct-spelling timing for benchmark JSON.

Lowercase English words, retaining contractions; punctuation is ignored.
British/American spelling, word splitting and digits are NOT silently fixed.
Timing uses the recognizer's estimated word ends, not acoustic ground truth.
"""
import argparse
import json
from pathlib import Path
import re


def tokens(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text.lower().replace("’", "'"))


def alignment(reference, hypothesis):
    n, m = len(reference), len(hypothesis)
    route = bytearray((n + 1) * (m + 1))
    previous = list(range(m + 1))
    for j in range(1, m + 1): route[j] = 2
    for i, a in enumerate(reference, 1):
        row = [i]; route[i * (m + 1)] = 1
        for j, b in enumerate(hypothesis, 1):
            candidates = (previous[j - 1] + (a != b), previous[j] + 1, row[-1] + 1)
            move = min(range(3), key=candidates.__getitem__)
            route[i * (m + 1) + j] = move; row.append(candidates[move])
        previous = row
    errors = {"substitutions": 0, "deletions": 0, "insertions": 0}
    matches, i, j = [], n, m
    while i or j:
        move = route[i * (m + 1) + j]
        if move == 0:
            i -= 1; j -= 1
            if reference[i] == hypothesis[j]: matches.append((i, j))
            else: errors["substitutions"] += 1
        elif move == 1: i -= 1; errors["deletions"] += 1
        else: j -= 1; errors["insertions"] += 1
    return errors, matches


def flattened(words):
    return [(token, word["end"]) for word in words for token in tokens(word["text"])]


def metrics(reference, report):
    expected, actual = tokens(reference), tokens(report["transcript"])
    errors, matches = alignment(expected, actual)
    result = {"referenceWords": len(expected), **errors, "wordErrors": sum(errors.values()),
              "wordErrorRate": sum(errors.values()) / max(1, len(expected)),
              "nativeMaximumSeconds": report["maximumSeconds"],
              "nativeOverThree": report.get("overThreeSeconds", report.get("overThree")),
              "measurement": "Reference-matched words only; omitted/wrong words counted as errors. Correct spelling uses its last lexical transition, not an earlier wrong spelling. Timings remain estimates from native word ends; no acoustic/paint ground truth."}
    events = report.get("events", [])
    if not events: return result
    final = flattened(events[-1]["words"])
    if [word for word, _ in final] != actual:
        result["timingUnavailable"] = "Final token words and displayed text do not align"
        return result
    seen = {}
    for event in events:
        current = {}
        for index, (word, _) in enumerate(flattened(event["words"])):
            old = seen.get(index)
            if old is None: current[index] = (word, event["received"], event["received"])
            elif old[0] != word: current[index] = (word, old[1], event["received"])
            else: current[index] = old
        # A rollback retracts absent words. If the same spelling appears again,
        # its old appearance cannot prove that it was available continuously.
        seen = current
    first, correct = [], []
    for _, index in matches:
        word, end = final[index]
        observed = seen.get(index)
        if observed is not None and observed[0] == word:
            first.append(max(0, observed[1] - end))
            correct.append(max(0, observed[2] - end))
    result.update(referenceMatchedWords=len(correct), firstAppearanceMaximumSeconds=max(first, default=0),
                  finalCorrectSpellingMaximumSeconds=max(correct, default=0),
                  correctSpellingOverThree=sum(delay > 3 for delay in correct))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("reports", type=Path, nargs="+")
    args = parser.parse_args()
    reference = args.reference.read_text()
    output = {path.name: metrics(reference, json.loads(path.read_text())) for path in args.reports}
    print(json.dumps(output, indent=2, sort_keys=True))
