#!/usr/bin/env python3
"""Suggest glossary terms from course materials the course pack does not cover yet.

Writes a TSV for review. Fill in the Chinese column for the terms you want,
delete the rest, then import it from 术语表 → 导入 TSV…. Rows whose Chinese
column is still empty are skipped on import, so a partly reviewed file is safe.

Candidates come from simple text statistics, not understanding: expect noise,
and expect some real terms to be missing. Every imported English term also
boosts recognition, so import only the terms you want boosted.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

REPOSITORY = Path(__file__).resolve().parents[1]

STOPWORDS = set("""
a about above after again against all also am an and any are as at be because been before being below between both but by
can could did do does doing down during each either etc few for from further had has have having he her here hers him his
how however i if in into is it its itself just let may me might more most must my no nor not now of off on once only or
other our ours out over own per same shall she should so some such than that the their them then there these they this
those through thus to too under until up upon us use used uses using very via was we well were what when where whether
which while who whom whose why will with within without would yes yet you your
""".split())

# Frequent words that are rarely worth a glossary entry on their own. Phrases
# are filtered by how many courses use them instead, so "primary key" survives.
COMMON = STOPWORDS | set("""
able across actually add added adding again ago allow allows almost along already always among another answer answers
anything appear apply approach area areas around ask asked available away back based basic become begin best better big
bit book both bottom bring build built call called calls came case cases cause certain change changes check choose class
classes clear close code come comes common complete consider contain contains content context continue control copy
correct course create created current data date day days deadline define defined describe described design detail details
different difficult directly discuss discussed done during each early easy either else end ends enough ensure enter
especially even every everything exactly example examples exercise exercises exist expect explain fact false feedback
figure file files final find first follow following form format found free full general get gets give given gives go goes
going good great group groups guide hand happen happens hard help here high hold home however idea ideas important include
included includes including information input instead interest introduction issue issues item items keep kind know known
lab labs large last later learn learning least left less level line lines link list little long look looks lot low main
make makes making many mark marks material materials mean means method methods might mind model module more move much name
names need needs never new next note notes number numbers often old one ones online open order other others outline output
overview page pages paper part parts pass past people perhaps place plan please point points possible practice present
previous probably problem problems process provide provides put question questions quite rather read reading real really
reason reasons record recap reference references related remember report required result results return review right room
rule rules run runs said say says school second section see seen select send sense set sets short show shows side simple
since single slide slides small solution solutions something sometimes source space specific start started state step steps
still stop student students study submit submission summary support sure system systems table take takes task tasks team
term terms test tests text thing things think three time times title today together tool tools top topic topics true try
turn two type types understand university unit until value values version view want way ways week weeks whole work works
world write written wrong year years
""".split())

ACRONYM_STOP = {"OK", "PDF", "PPT", "AM", "PM", "UK", "US", "USA", "EU", "UOG", "MSC", "BSC", "PHD", "II", "III", "IV", "VI",
                "VII", "VIII", "IX", "XI", "XII", "TODO", "FAQ", "NB", "PS", "CW", "Q&A", "COMPSCI", "UNI", "ID", "IDS"}

SEGMENT = re.compile(r"[\n\r.;:!?•▪●◦·|()\[\]{}\"“”]+|\s[-–—]\s")
WORD = re.compile(r"[A-Za-z][A-Za-z0-9+#]*(?:['’-][A-Za-z0-9]+)*")


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def normalized(text):
    """The spelling-insensitive key used to compare terms, like the app's matcher."""
    words = re.sub(r"[-‐‑–—_]+", " ", text.lower().replace("’", "'")).split()
    if not words:
        return ""
    last = words[-1]
    if len(last) > 4 and last.endswith("ies"):
        last = last[:-3] + "y"
    elif len(last) > 4 and re.search(r"(?:ss|x|ch|sh)es$", last):
        last = last[:-2]
    elif len(last) > 3 and last.endswith("s") and not last.endswith("ss"):
        last = last[:-1]
    return " ".join(words[:-1] + [last])


def pptx_slides(path):
    """Slide texts in presentation order, numbered from 1."""
    with zipfile.ZipFile(path) as bundle:
        names = set(bundle.namelist())
        order = []
        if "ppt/presentation.xml" in names and "ppt/_rels/presentation.xml.rels" in names:
            relations = bundle.read("ppt/_rels/presentation.xml.rels").decode("utf-8", "replace")
            targets = {}
            for tag in re.findall(r"<Relationship\b[^>]*>", relations):
                ident, target = re.search(r'\bId="([^"]+)"', tag), re.search(r'\bTarget="([^"]+)"', tag)
                if ident and target:
                    targets[ident.group(1)] = "ppt/" + target.group(1).lstrip("/").removeprefix("ppt/")
            presentation = bundle.read("ppt/presentation.xml").decode("utf-8", "replace")
            for tag in re.findall(r"<p:sldId\b[^>]*>", presentation):
                ident = re.search(r'\br:id="([^"]+)"', tag)
                if ident and targets.get(ident.group(1)) in names:
                    order.append(targets[ident.group(1)])
        if not order:
            order = sorted((n for n in names if re.fullmatch(r"ppt/slides/slide\d+\.xml", n)),
                           key=lambda n: int(re.search(r"(\d+)\.xml$", n).group(1)))
        for number, name in enumerate(order, 1):
            xml = bundle.read(name).decode("utf-8", "replace")
            paragraphs = []
            for paragraph in re.findall(r"<a:p\b(?!Pr).*?</a:p>", xml, flags=re.S):
                runs = re.findall(r"<a:t(?:\s[^>]*)?>(.*?)</a:t>", paragraph, flags=re.S)
                text = html.unescape("".join(runs)).strip()
                if text:
                    paragraphs.append(text)
            yield number, "\n".join(paragraphs)


def pdf_pages(paths):
    """{path: [(page, text)]} via PDFKit; empty without macOS developer tools."""
    pages = defaultdict(list)
    if not paths:
        return pages
    if not shutil.which("xcrun"):
        print(f"PDF text needs macOS with Xcode Command Line Tools; skipped {len(paths)} PDF files.", file=sys.stderr)
        return pages
    result = subprocess.run(["xcrun", "swift", str(REPOSITORY / "Scripts/pdf-text.swift"), *map(str, paths)],
                            check=True, capture_output=True, text=True)
    sys.stderr.write(result.stderr)
    for line in result.stdout.splitlines():
        item = json.loads(line)
        pages[Path(item["file"])].append((item["page"], item["text"]))
    return pages


def long_form(short, words):
    """Schwartz-Hearst: the shortest run of words ending before "(short)" that spells it."""
    letters = [c.lower() for c in short.rstrip("s") if c.isalnum()]
    if len(letters) < 2:
        return None
    text = " ".join(words[-min(len(letters) + 5, len(letters) * 2):])
    s, l = len(letters) - 1, len(text) - 1
    while s >= 0:
        while l >= 0 and (text[l].lower() != letters[s] or (s == 0 and l > 0 and text[l - 1].isalnum())):
            l -= 1
        if l < 0:
            return None
        l -= 1
        s -= 1
    start = text.rfind(" ", 0, l + 1) + 1
    found = text[start:].strip(" -")
    return found if len(found.split()) >= 2 and normalized(found) != normalized(short) else None


class Candidate:
    def __init__(self):
        self.forms = Counter()
        self.count = 0
        self.pages = set()
        self.first = None
        self.defined = False


def add(table, form, file, page, text, defined=False):
    key = normalized(form)
    if not key:
        return
    item = table[key]
    item.forms[form] += 1
    item.count += 1
    item.pages.add((file, page))
    item.defined = item.defined or defined
    if item.first is None:
        flat = " ".join(text.split())
        at = flat.lower().find(form.lower())
        snippet = flat[max(0, at - 70):at + len(form) + 70] if at >= 0 else ""
        item.first = (file, page, snippet.strip())


LINKING = {"of", "and", "in", "to", "as", "for"}   # "denial of service", "separation of concerns"


def scan(text, file, page, table):
    """Collect candidates from one page or slide."""
    flat = " ".join(text.split())
    # Definitions such as "Role-Based Access Control (RBAC)": both spellings.
    for match in re.finditer(r"\(\s*([A-Z][A-Za-z0-9&]{1,9})\s*\)", flat):
        short = match.group(1)
        if sum(c.isupper() for c in short) < 2:
            continue
        full = long_form(short, WORD.findall(flat[max(0, match.start() - 200):match.start()]))
        if full:
            add(table, full, file, page, text, defined=True)
            add(table, short, file, page, text, defined=True)
    for segment in SEGMENT.split(text):
        tokens = WORD.findall(segment)
        for i, token in enumerate(tokens):
            acronym = re.fullmatch(r"[A-Z][A-Z0-9&]{1,6}s?", token) and sum(c.isupper() for c in token) >= 2
            camel = re.search(r"[a-z][A-Z]|^[A-Z]{2,}[a-z]", token) and not re.fullmatch(r"[A-Z]{2,}s", token)
            if acronym and token.rstrip("s") not in ACRONYM_STOP and token.lower() not in COMMON or camel:
                add(table, token, file, page, text)
            # Plain words; a capital only counts away from the start of a line.
            elif (len(token) >= 5 and token[1:].islower() and (token.islower() or i > 0)
                  and token.lower() not in COMMON and normalized(token) not in COMMON):
                add(table, token, file, page, text)
            for size in (2, 3):
                gram = tokens[i:i + size]
                if len(gram) < size or any(len(w) < 2 or re.search(r"\d", w) for w in gram):
                    continue
                lower = [w.lower() for w in gram]
                if lower[0] in STOPWORDS or lower[-1] in STOPWORDS or (size == 3 and lower[1] in STOPWORDS and lower[1] not in LINKING):
                    continue
                # Keep "SQL injection" as written; fold title case to lower case.
                form = " ".join(gram) if any(w[1:] != w[1:].lower() for w in gram) else " ".join(lower)
                add(table, form, file, page, text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--materials", type=Path, default=Path(os.environ.get("LECTURELENS_MOODLE_DIR", Path.home() / "Desktop" / "Moodle课程资料")).expanduser())
    local_pack = REPOSITORY / "Resources/coursepack.json"
    parser.add_argument("--pack", type=Path, default=local_pack if local_pack.exists() else REPOSITORY / "Resources/coursepack.portable.json")
    parser.add_argument("--preferences", type=Path, default=Path.home() / "Library/Application Support/LectureLens/preferences.json",
                        help="Terms already added in the app are left out")
    parser.add_argument("--output", type=Path, default=Path.home() / "Desktop" / "Lecture Lens 候选词.tsv")
    parser.add_argument("--all", action="store_true", help="Also suggest terms from materials the course pack already covers")
    parser.add_argument("--per-course", type=int, default=40, help="Most candidates listed per course (default 40)")
    parser.add_argument("--min-count", type=int, default=2, help="Least occurrences for a candidate (default 2)")
    args = parser.parse_args()

    materials = args.materials.resolve()
    if not materials.is_dir():
        sys.exit(f"Course materials folder not found: {materials}\nSet --materials or LECTURELENS_MOODLE_DIR.")
    pack = json.loads(args.pack.read_text(encoding="utf-8"))
    covered, folders = set(), {}
    for term in pack["terms"]:
        for reference in term.get("references") or []:
            covered.add(reference["sha256"])
            folders[Path(reference["relative"]).parts[0]] = term["course"]
    known = {normalized(term["english"]) for term in pack["terms"]}
    if args.preferences.is_file():
        known |= {normalized(term["english"]) for term in json.loads(args.preferences.read_text(encoding="utf-8")).get("terms", [])}

    files, skipped = [], 0
    for path in sorted(materials.rglob("*")):
        relative = path.relative_to(materials)
        if not path.is_file() or any(part.startswith((".", "~$")) for part in relative.parts):
            continue
        if path.suffix.lower() == ".ppt":
            skipped += 1
            continue
        if path.suffix.lower() not in {".pdf", ".pptx"}:
            continue
        top = relative.parts[0] if len(relative.parts) > 1 else ""
        code = folders.get(top) or (re.search(r"COMPSCI\s*_?(\d{4}[A-Z]?)", top, re.I) or [None, "General"])[1]
        files.append((path, relative, code, digest(path) not in covered))
    targets = [item for item in files if args.all or item[3]]
    print(f"{len(files)} course files; {sum(item[3] for item in files)} not yet in the course pack.", file=sys.stderr)
    if skipped:
        print(f"Skipped {skipped} old .ppt files; save them as .pptx or PDF to include them.", file=sys.stderr)
    if not targets:
        print("Nothing new to scan. Use --all to scan every file.", file=sys.stderr)
        return

    pdfs = pdf_pages([path for path, _, _, _ in files if path.suffix.lower() == ".pdf"])
    pages = {}
    for path, relative, code, _ in files:
        try:
            pages[path] = list(pptx_slides(path)) if path.suffix.lower() == ".pptx" else pdfs.get(path, [])
        except (zipfile.BadZipFile, KeyError, OSError) as error:
            print(f"Cannot read {relative}: {error}", file=sys.stderr)
            pages[path] = []

    # How many courses use each candidate, over every file, so wording common
    # to all lectures ("next week", "learning outcomes") ranks low.
    usage = defaultdict(set)
    for path, _, code, _ in files:
        table = defaultdict(Candidate)
        for page, text in pages[path]:
            scan(text, path, page, table)
        for key in table:
            usage[key].add(code)
    courses = max(1, len({code for _, _, code, _ in files}))

    rows = []
    for code in sorted({code for _, _, code, _ in targets}):
        table = defaultdict(Candidate)
        for path, _, file_code, _ in targets:
            if file_code == code:
                for page, text in pages[path]:
                    scan(text, path, page, table)
        scored = []
        for key, item in table.items():
            spread, words = len(usage[key]) or 1, key.split()
            form = item.forms.most_common(1)[0][0]
            if key in known or spread > max(1, courses // 2):
                continue
            if not item.defined:
                if item.count < args.min_count:
                    continue
                # An ordinary word alone needs to be frequent and specific to this
                # course; acronyms and names such as NumPy need less.
                special = re.search(r"[A-Z].*[A-Z]|[a-z][A-Z]", form)
                if len(words) == 1 and not special and (spread > 1 or item.count < args.min_count + 2):
                    continue
                if len(words) > 1 and len(item.pages) < 2:
                    continue
                # Everyday words together ("next week") need more evidence than "primary key".
                if len(words) > 1 and all(w in COMMON for w in words) and (item.count < args.min_count + 2 or len(item.pages) < 3):
                    continue
            score = item.count * math.log(1 + courses / spread) * (3 if item.defined else 1)
            scored.append((score, key, item))
        # Drop a fragment such as "role based access" when a longer candidate
        # that contains it accounts for most of its uses.
        kept = []
        for entry in sorted(scored, key=lambda entry: -len(entry[1].split())):
            _, key, item = entry
            if not any(f" {key} " in f" {longer} " and other.count >= 0.8 * item.count for _, longer, other in kept):
                kept.append(entry)
        kept.sort(key=lambda entry: (-entry[0], entry[1]))
        for _, key, item in kept[:args.per_course]:
            file, page, snippet = item.first
            kind = "幻灯片" if file.suffix.lower() == ".pptx" else "PDF"
            others = len({path for path, _ in item.pages}) - 1
            source = f"课件候选：{file.name} · {kind} 第 {page} 页" + (f"（另见 {others} 份课件）" if others else "")
            explanation = f"课件原文：…{snippet}…" if snippet else ""
            rows.append([item.forms.most_common(1)[0][0], "", explanation, code, source])

    clean = lambda value: " ".join(str(value).replace("\t", " ").split())
    header = [
        "# Lecture Lens 候选词：在第 2 列填写中文，删除不需要的行，然后在“术语表 → 导入 TSV…”导入。",
        "# 中文留空的行导入时会跳过。第 3 列是课件原文，可改成中文解释。导入的英文词也会用于专业词增强，只保留需要的词。",
        "# 列：英文 ⇥ 中文 ⇥ 解释 ⇥ 课程 ⇥ 出处",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(header + ["\t".join(map(clean, row)) for row in rows]) + "\n", encoding="utf-8")
    print(f"Wrote {len(rows)} candidates for {len({row[3] for row in rows})} courses: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
