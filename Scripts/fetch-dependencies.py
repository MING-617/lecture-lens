#!/usr/bin/env python3
"""Restore pinned models and build the pinned upstream native runtime."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def matches(path, expected):
    return path.is_file() and digest(path) == expected


def download(url, path, expected):
    if matches(path, expected):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".download")
    try:
        subprocess.run(["curl", "--fail", "--location", "--retry", "2", "--connect-timeout", "20", "--output", str(temporary), url], check=True)
        if digest(temporary) != expected:
            raise ValueError(f"Checksum mismatch: {path.name}")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def restore_archive(url, archive, archive_sha, directory, files):
    if all(matches(directory / name, checksum) for name, checksum in files.items()):
        print(f"Verified: {directory.name}")
        return
    download(url, archive, archive_sha)
    directory.mkdir(parents=True, exist_ok=True)
    found = set()
    # Read selected regular files in one streaming pass. Never extract paths
    # or links from the archive, and do not inflate the model into memory.
    with tarfile.open(archive, mode="r|bz2") as bundle:
        for member in bundle:
            name = Path(member.name).name
            if name not in files:
                continue
            if not member.isfile() or name in found:
                raise ValueError(f"Unexpected archive member: {member.name}")
            found.add(name)
            target = directory / name
            temporary = target.with_name(name + ".extract")
            try:
                with bundle.extractfile(member) as stream, temporary.open("wb") as output:
                    shutil.copyfileobj(stream, output, length=1024 * 1024)
                if digest(temporary) != files[name]:
                    raise ValueError(f"Checksum mismatch: {name}")
                temporary.replace(target)
            finally:
                temporary.unlink(missing_ok=True)
    if found != set(files):
        raise ValueError(f"Missing archive files: {sorted(set(files) - found)}")


def main():
    repository = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=repository / ".cache" / "dependencies")
    parser.add_argument("--destination", type=Path, default=repository, help="Optional restoration directory for verification")
    args = parser.parse_args()
    model = json.loads((repository / "Resources/StreamingEnglish/model-manifest.json").read_text())
    runtime = json.loads((repository / "Vendor/SherpaOnnx/checksums.json").read_text())
    target_model = args.destination / "Resources/StreamingEnglish"
    target_runtime = args.destination / "Vendor/SherpaOnnx"
    restore_archive(model["model_source"], args.cache / "nemotron-model.tar.bz2", model["model_archive_sha256"], target_model,
                    {name: checksum for name, checksum in model["files"].items() if name != "silero_vad.onnx"})
    if not matches(target_runtime / "c-api.h", runtime["header_sha256"]) or not all(matches(target_runtime / name, checksum) for name, checksum in runtime["files"].items()):
        subprocess.run([sys.executable, str(repository / "Scripts/build-native.py"), "--destination", str(args.destination.resolve()), "--cache", str((args.cache / "native").resolve())], check=True)
    target_model.mkdir(parents=True, exist_ok=True)
    download(model["vad"]["source"], target_model / "silero_vad.onnx", model["vad"]["sha256"])
    if digest(target_runtime / "c-api.h") != runtime["header_sha256"]:
        raise ValueError("The checked-in C API header does not match this runtime")
    vocabulary = "".join(line.rsplit(" ", 1)[0] + "\t-1.0\n" for line in (target_model / "tokens.txt").read_text().splitlines())
    (target_model / "bpe.vocab").write_text(vocabulary)
    if digest(target_model / "bpe.vocab") != model["bpe_vocab_sha256"]:
        raise ValueError("BPE vocabulary checksum mismatch")
    print("All dependency sources and model checksums verified.")


if __name__ == "__main__":
    main()
