"""Late spelling and retracted words must not inherit an earlier wrong delay."""
import importlib.util
from pathlib import Path

source = Path(__file__).resolve().parents[1] / "Scripts/vocabulary-metrics.py"
spec = importlib.util.spec_from_file_location("vocabulary_metrics", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def event(time, text):
    return {"received": time, "words": [{"text": text, "end": 1.0}] if text else []}


def report(events):
    return {"transcript": "schema", "maximumSeconds": 7, "overThreeSeconds": 1, "events": events}


revised = module.metrics("schema", report([event(1.2, "skimmer"), event(8, "schema")]))
assert revised["firstAppearanceMaximumSeconds"] < 1
assert revised["finalCorrectSpellingMaximumSeconds"] == 7
assert revised["correctSpellingOverThree"] == 1
retracted = module.metrics("schema", report([event(1.2, "schema"), event(2, ""), event(8, "schema")]))
assert retracted["firstAppearanceMaximumSeconds"] == 7
assert retracted["finalCorrectSpellingMaximumSeconds"] == 7
assert retracted["correctSpellingOverThree"] == 1
print("PASS: independent reference metrics retain late correct spellings and reset retracted appearances")
