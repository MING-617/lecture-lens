"""Candidate terms: definitions, slide order, course-specific phrases and the skipped boilerplate."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

source = Path(__file__).resolve().parents[1] / "Scripts/extract-terms.py"
spec = importlib.util.spec_from_file_location("extract_terms", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def slides(path, texts, reverse=False):
    """A minimal .pptx; with reverse, presentation order is the opposite of file numbering."""
    path.parent.mkdir(parents=True, exist_ok=True)
    order = list(range(1, len(texts) + 1))[::-1 if reverse else 1]
    with zipfile.ZipFile(path, "w") as bundle:
        bundle.writestr("ppt/_rels/presentation.xml.rels", "<Relationships>" + "".join(
            f'<Relationship Id="rId{n}" Type="slide" Target="slides/slide{n}.xml"/>' for n in order) + "</Relationships>")
        bundle.writestr("ppt/presentation.xml", "<p:presentation><p:sldIdLst>" + "".join(
            f'<p:sldId id="{255 + n}" r:id="rId{n}"/>' for n in order) + "</p:sldIdLst></p:presentation>")
        for n, text in enumerate(texts, 1):
            body = "".join(f'<a:p><a:pPr lvl="0"/><a:r><a:t>{line.replace("&", "&amp;")}</a:t></a:r></a:p>' for line in text.split("\n"))
            bundle.writestr(f"ppt/slides/slide{n}.xml", f"<p:sld>{body}</p:sld>")


assert module.long_form("RBAC", "We use Role-Based Access Control".split()) == "Role-Based Access Control"
assert module.long_form("DBMS", "a Database Management System".split()) == "Database Management System"
assert module.long_form("SQL", "uses a query language".split()) is None, "letters inside words cannot start a long form"
assert module.normalized("Foreign Keys") == module.normalized("foreign-key") == "foreign key"
assert module.normalized("dependencies") == "dependency" and module.normalized("class") == "class"

with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    slides(root / "deck.pptx", ["first", "second", "third"], reverse=True)
    assert [text for _, text in module.pptx_slides(root / "deck.pptx")] == ["third", "second", "first"], "slides follow presentation order"

    materials = root / "Moodle"
    boilerplate = "Learning outcomes\nNext week we will look at the coursework deadline."
    for folder_name in ["01_COMPSCI4039_Programming", "02_COMPSCI4043_Systems_and_Networks", "04_COMPSCI5059_Software_Engineering"]:
        slides(materials / folder_name / "PPT/Wk06.pptx", [boilerplate, "routine content"])
    slides(materials / "05_COMPSCI5076_Database_Data_Analytics/PPT/Week5.pptx", [
        "Third normal form removes transitive dependencies.\nA foreign key check",
        "Boyce-Codd Normal Form (BCNF)\nA functional dependency X -> Y",
        "BCNF is stricter than third normal form.\nEvery functional dependency has a determinant.",
        "Foreign keys again\nforeign key rules", boilerplate])
    slides(materials / "07_COMPSCI5012_Internet_Technology/Wk1.pptx", ["HTTP requests\nHTTP responses", boilerplate])
    pack = root / "pack.json"
    pack.write_text(json.dumps({"terms": [{"english": "foreign key", "course": "5076", "references": [
        {"relative": "05_COMPSCI5076_Database_Data_Analytics/PPT/Old.pdf", "sha256": "0" * 64}]}]}))
    output = root / "candidates.tsv"
    subprocess.run([sys.executable, str(source), "--materials", str(materials), "--pack", str(pack),
                    "--preferences", str(root / "missing.json"), "--output", str(output)], check=True, capture_output=True)
    rows = [line.split("\t") for line in output.read_text(encoding="utf-8").splitlines() if not line.startswith("#")]
    found = {(row[0], row[3]) for row in rows}
    assert all(len(row) == 5 and row[1] == "" for row in rows), "five columns, Chinese left for review"
    assert {("Boyce-Codd Normal Form", "5076"), ("BCNF", "5076"), ("functional dependency", "5076"),
            ("third normal form", "5076"), ("HTTP", "5012")} <= found, found
    english = {row[0].lower() for row in rows}
    # Frequent enough to be listed, but the course pack already has it.
    pack.write_text(json.dumps({"terms": []}))
    subprocess.run([sys.executable, str(source), "--materials", str(materials), "--pack", str(pack),
                    "--preferences", str(root / "missing.json"), "--output", str(output)], check=True, capture_output=True)
    assert "foreign key" in output.read_text(encoding="utf-8").lower(), "control: the phrase qualifies on its own"
    assert not english & {"foreign key", "foreign keys", "next week", "learning outcomes", "coursework deadline"}, english
    assert all("课件候选：" in row[4] and "页" in row[4] for row in rows)

print("PASS: candidate terms keep definitions and course-specific phrases in slide order, skip known terms and shared boilerplate, and stay importable")
