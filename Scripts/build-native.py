#!/usr/bin/env python3
"""Build the pinned upstream NeMo hotword runtime locally on Apple Silicon."""
import argparse
import importlib.util
import json
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tarfile

spec = importlib.util.spec_from_file_location("fetch_dependencies", Path(__file__).with_name("fetch-dependencies.py"))
dependencies = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dependencies)
download, digest = dependencies.download, dependencies.digest


def build(repository, destination, cache):
    manifest = json.loads((repository / "Vendor/SherpaOnnx/checksums.json").read_text())
    runtime = destination / "Vendor/SherpaOnnx"
    receipt = cache / "runtime-receipt.json"
    patch = repository / "Vendor/SherpaOnnx/bounded-revisions.patch"
    patch_sha = digest(patch)
    if patch_sha != manifest["patch_sha256"]: raise ValueError("Native patch checksum mismatch")
    if receipt.exists():
        old = json.loads(receipt.read_text())
        if old.get("commit") == manifest["source_commit"] and old.get("patch") == patch_sha and all(
            (runtime / name).is_file() and digest(runtime / name) == sha for name, sha in old["files"].items()
        ):
            print("Verified pinned native runtime"); return
    archive = cache / "sherpa-source.tar.gz"
    download(manifest["source_url"], archive, manifest["source_sha256"])
    source = cache / ("sherpa-onnx-" + manifest["source_commit"])
    applied = cache / "applied-patch.sha256"
    extracted = cache / "extracted-source.sha256"
    if not extracted.exists():
        with tarfile.open(archive) as bundle:
            for member in bundle:
                target = (cache / member.name).resolve()
                if not target.is_relative_to(cache.resolve()):
                    raise ValueError("Unexpected source archive entry")
                if member.issym():
                    # API/example links are not used by the C++ runtime build;
                    # the official archive also contains absolute Go links.
                    continue
                elif not (member.isfile() or member.isdir()):
                    raise ValueError("Unsupported source archive entry")
                bundle.extract(member, cache)
        extracted.write_text(manifest["source_sha256"])
        if applied.exists(): applied.unlink()
    elif extracted.read_text() != manifest["source_sha256"]:
        raise ValueError("Cached source archive differs; use a fresh cache")
    if not applied.exists():
        # This cache may sit inside the app's Git checkout. Use patch's cwd
        # rather than letting git apply resolve paths against the outer repo.
        subprocess.run(["patch", "-p1", "--dry-run", "-i", str(patch.resolve())], cwd=source, check=True)
        subprocess.run(["patch", "-p1", "-i", str(patch.resolve())], cwd=source, check=True)
        applied.write_text(patch_sha)
    elif applied.read_text() != patch_sha:
        raise ValueError("Cached native source has a different patch; use a fresh cache")
    # Isolate build tooling from the user's system Python and global packages.
    tools = cache / "tools"
    cmake = tools / "cmake/data/bin/cmake"
    if not cmake.exists():
        subprocess.run([sys.executable, "-m", "pip", "install", "--target", str(tools), "cmake==3.31.6"], check=True)
    build_dir, install = cache / "build", cache / "install"
    options = ["CMAKE_BUILD_TYPE=Release", "CMAKE_OSX_ARCHITECTURES=arm64", "CMAKE_OSX_DEPLOYMENT_TARGET=26.0",
        "BUILD_SHARED_LIBS=ON", "SHERPA_ONNX_ENABLE_C_API=ON", "SHERPA_ONNX_ENABLE_TTS=OFF",
        "SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF", "SHERPA_ONNX_ENABLE_BINARY=OFF",
        "SHERPA_ONNX_ENABLE_PORTAUDIO=OFF", "SHERPA_ONNX_ENABLE_WEBSOCKET=OFF",
        "SHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF", "SHERPA_ONNX_ENABLE_TESTS=OFF",
        "SHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=OFF", "CMAKE_INSTALL_PREFIX=" + str(install)]
    subprocess.run([str(cmake), "-S", str(source), "-B", str(build_dir)] + ["-D" + x for x in options], check=True)
    subprocess.run([str(cmake), "--build", str(build_dir), "-j", "6"], check=True)
    subprocess.run([str(cmake), "--install", str(build_dir)], check=True)
    runtime.mkdir(parents=True, exist_ok=True)
    header = install / "include/sherpa-onnx/c-api/c-api.h"
    if digest(header) != manifest["header_sha256"]:
        raise ValueError("Pinned runtime header checksum mismatch")
    shutil.copyfile(header, runtime / "c-api.h")
    files = {}
    for name in ["libonnxruntime.dylib", "libsherpa-onnx-c-api.dylib"]:
        target = runtime / name
        shutil.copyfile(install / "lib" / name, target)
        subprocess.run(["install_name_tool", "-id", "@rpath/" + name, str(target)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True)
        files[name] = digest(target)
    files["c-api.h"] = digest(runtime / "c-api.h")
    receipt.write_text(json.dumps({"commit": manifest["source_commit"], "patch": patch_sha, "files": files}, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--cache", type=Path)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    build(repository, (args.destination or repository).resolve(), (args.cache or repository / ".cache/native-build").resolve())
