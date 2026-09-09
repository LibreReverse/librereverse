#!/usr/bin/env python3
"""Package and validate the complete Mach-O dependency graph of LibreReverse."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

WHISPER_REVISION = "978113305b2ead22249b881deafa131dc8884911"

MODEL_HASHES = {
    "ggml-large-v3-turbo.bin": "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
    "ggml-silero-v6.2.0.bin": "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
}
SPEECH_SOURCE_SHA = "ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe"
SPEECH_LICENSES = ("WEBRTC_COPYING.txt", "WEBRTC_LICENSE.txt", "WEBRTC_PATENTS.txt", "ABSEIL_LICENSE.txt", "PFFFT_LICENSE.txt", "RNNOISE_COPYING.txt")
THIRD_PARTY_LICENSES = ("SQLCipher.txt", "OpenSSL.txt", "Whisper-model.txt", "Silero-VAD.txt", "Swift-XID.txt")
SYSTEM_PREFIXES = ("/System/Library/", "/usr/lib/")


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def dependencies(output):
    """Parse otool -L including names containing spaces and universal headers."""
    result = []
    for line in output.splitlines():
        match = re.match(r"\s+(.+?) \(compatibility version .+\)$", line)
        if match and match.group(1) not in result:
            result.append(match.group(1))
    return result


def load_commands(output):
    rpaths, minimums = [], []
    for block in re.split(r"Load command \d+", output):
        if re.search(r"\bcmd LC_RPATH\b", block):
            match = re.search(r"\bpath (.+?) \(offset \d+\)", block)
            if match:
                rpaths.append(match.group(1))
        if re.search(r"\bcmd LC_BUILD_VERSION\b", block):
            match = re.search(r"\bminos ([\d.]+)", block)
            if match:
                minimums.append(match.group(1))
        if re.search(r"\bcmd LC_VERSION_MIN_MACOSX\b", block):
            match = re.search(r"\bversion ([\d.]+)", block)
            if match:
                minimums.append(match.group(1))
    return rpaths, minimums


def version_tuple(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * max(0, 3 - len(parts))


def is_system(path):
    return str(path).startswith(SYSTEM_PREFIXES)


def expand(path, owner, executable):
    return path.replace("@loader_path", str(owner.parent)).replace(
        "@executable_path", str(executable.parent)
    )


def resolve_dependency(name, owner, executable, inherited_rpaths=()):
    if is_system(name):
        return Path(name)
    rpaths, _ = load_commands(run("otool", "-l", owner))
    candidates = []
    if name.startswith("@rpath/"):
        for rpath in [*rpaths, *inherited_rpaths]:
            candidates.append(Path(expand(rpath, owner, executable)) / name[len("@rpath/"):])
    else:
        candidates.append(Path(expand(name, owner, executable)))
    candidates = [candidate.resolve() if candidate.is_absolute() else candidate for candidate in candidates]
    for candidate in candidates:
        if candidate.is_absolute() and candidate.is_file():
            return candidate.resolve()
    # Swift runtime libraries may exist only in the dyld shared cache. An
    # arbitrary missing @rpath dependency must not be accepted merely because
    # the executable also searches /usr/lib/swift (e.g. missing SQLCipher).
    for candidate in candidates:
        if str(candidate).startswith('/usr/lib/swift/') and candidate.name.startswith('libswift') and candidate.suffix == '.dylib':
            return candidate
    raise ValueError(f"Unresolved dependency {name!r} in {owner}")


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def verify_runtime(runtime, patch):
    manifest = json.loads((runtime / 'runtime-build.json').read_text())
    expected = {
        'sourceRevision': WHISPER_REVISION,
        'patchSHA256': digest(patch),
        'helperSHA256': digest(runtime / 'bin/whisper-cli'),
        'ggmlNative': False,
        'armArchitecture': 'armv8-a',
    }
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError('Native runtime provenance or CPU baseline mismatch; rerun prepare_whisper_cpp_runtime.sh')
    for name, expected_hash in MODEL_HASHES.items():
        if digest(runtime / 'Models' / name) != expected_hash:
            raise ValueError(f'Required Whisper model checksum mismatch: {name}')


def verify_speech_runtime(runtime):
    try:
        metadata = json.loads((runtime / 'runtime-build.json').read_text())
        wrapper = Path(__file__).resolve().parent / 'native/LibreReverseSpeech.cpp'
        expected = {
            'webrtcVersion': '2.1', 'sourceSHA256': SPEECH_SOURCE_SHA,
            'abseilVersion': '20240722.0', 'wrapperSHA256': digest(wrapper),
            'librarySHA256': digest(runtime / 'libLibreReverseSpeech.dylib'),
        }
        if any(metadata.get(key) != value for key, value in expected.items()):
            raise ValueError('Speech runtime provenance or binary changed')
        for name in SPEECH_LICENSES:
            if not (runtime / 'licenses' / name).read_bytes().strip():
                raise ValueError('Speech runtime license is empty')
    except (OSError, ValueError) as error:
        raise ValueError('Run python3 scripts/prepare_speech_runtime.py: ' + str(error)) from error


def bundle_dependencies(app, source_main, source_helper):
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    roots = [(source_main.resolve(), app / "Contents/MacOS/LibreReverse"),
             (source_helper.resolve(), app / "Contents/Resources/Transcription/whisper-cli")]
    copied, visited, records = {}, set(), []

    def visit(source, destination, executable, inherited_rpaths):
        if source in visited:
            return
        visited.add(source)
        rpaths, _ = load_commands(run("otool", "-l", source))
        inherited = [expand(path, source, executable) for path in rpaths] + list(inherited_rpaths)
        ids = run("otool", "-D", source).splitlines()[1:]
        ids = {line.strip() for line in ids if line.strip() and not line.endswith(":")}
        for dependency in dependencies(run("otool", "-L", source)):
            if dependency in ids:  # LC_ID_DYLIB is not an import.
                continue
            resolved = resolve_dependency(dependency, source, executable, inherited)
            if is_system(resolved):
                continue
            if ".framework/" in str(resolved):
                raise ValueError(f"Non-system framework needs explicit resource packaging: {resolved}")
            target = frameworks / resolved.name
            previous = copied.get(target.name)
            if previous is not None and previous != resolved:
                raise ValueError(f"Conflicting dependency basenames: {previous} and {resolved}")
            if previous is None:
                copied[target.name] = resolved
                shutil.copy2(resolved, target)
                target.chmod(0o755)
                records.append({"file": target.name, "sourceSHA256": digest(resolved)})
                run("install_name_tool", "-id", f"@rpath/{target.name}", target)
                visit(resolved, target, executable, inherited)
            relative = os.path.relpath(target, destination.parent)
            run("install_name_tool", "-change", dependency, f"@loader_path/{relative}", destination)
        # The original build's absolute rpaths must not remain a fallback into
        # Homebrew or a developer directory after every import is rewritten.
        for rpath in dict.fromkeys(rpaths):
            if not is_system(rpath):
                run("install_name_tool", "-delete_rpath", rpath, destination)

    for source, target in roots:
        visit(source, target, source, ())
    (app / "Contents/Resources/native-dependencies.json").write_text(
        json.dumps(sorted(records, key=lambda record: record["file"]), indent=2) + "\n"
    )


def verify_third_party_licenses(contents):
    for name in THIRD_PARTY_LICENSES:
        path = contents / "Resources/Licenses" / name
        if path.is_symlink() or not path.is_file() or not path.read_bytes().strip():
            raise ValueError("Missing or empty bundled third-party license: " + name)


def validate(app):
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleExecutable") != "LibreReverse":
        raise ValueError("CFBundleExecutable must be LibreReverse")
    minimum = version_tuple(info["LSMinimumSystemVersion"])
    main = contents / "MacOS/LibreReverse"
    helper = contents / "Resources/Transcription/whisper-cli"
    required_arches = set(run("lipo", "-archs", main).split())
    binaries = [main, helper, *sorted((contents / "Frameworks").glob("*"))]
    for binary in binaries:
        if not binary.is_file() or binary.is_symlink():
            raise ValueError(f"Expected regular bundled binary: {binary}")
        if not required_arches.issubset(set(run("lipo", "-archs", binary).split())):
            raise ValueError(f"Architecture mismatch: {binary}")
        rpaths, minimums = load_commands(run("otool", "-l", binary))
        if not minimums or any(version_tuple(value) > minimum for value in minimums):
            raise ValueError(f"Bundle minimum OS does not cover {binary}: {minimums}")
        for rpath in rpaths:
            if not is_system(rpath):
                raise ValueError(f"Unexpected runtime search path {rpath!r} in {binary}")
        ids = {line.strip() for line in run("otool", "-D", binary).splitlines()[1:]}
        for dependency in dependencies(run("otool", "-L", binary)):
            if dependency in ids or is_system(dependency):
                continue
            executable = helper if binary == helper else main
            resolved = resolve_dependency(dependency, binary, executable)
            if is_system(resolved):
                continue
            if not resolved.is_relative_to(contents.resolve()):
                raise ValueError(f"Dependency escapes bundle: {dependency} in {binary}")
    for name, expected in MODEL_HASHES.items():
        path = contents / "Resources/Transcription/Models" / name
        if digest(path) != expected:
            raise ValueError(f"Model checksum mismatch: {name}")
    fpng_license = contents / "Resources/FPNG_LICENSE.txt"
    if (not fpng_license.is_file() or fpng_license.is_symlink()
            or not fpng_license.read_bytes().strip()):
        raise ValueError("Missing or empty bundled FPNG license")
    verify_third_party_licenses(contents)
    if not (contents / "Resources/Transcription/WHISPER_CPP_LICENSE.txt").is_file():
        raise ValueError("Missing whisper.cpp license")
    runtime_manifest = json.loads((contents / 'Resources/Transcription/runtime-build.json').read_text())
    if (runtime_manifest.get('sourceRevision') != WHISPER_REVISION
            or runtime_manifest.get('ggmlNative') is not False
            or runtime_manifest.get('armArchitecture') != 'armv8-a'
            or runtime_manifest.get('patchSHA256') != digest(Path(__file__).resolve().parent / 'patches/whisper-cli-vad-token-clock.patch')):
        raise ValueError('Bundled runtime metadata does not match the supported native source and CPU baseline')
    if not (contents / 'Frameworks/libLibreReverseSpeech.dylib').is_file():
        raise ValueError('Missing standalone WebRTC microphone processor')
    speech = contents / 'Resources/Speech'
    for name in SPEECH_LICENSES:
        license_path = speech / name
        if license_path.is_symlink() or not license_path.is_file() or not license_path.read_bytes().strip():
            raise ValueError('Missing or empty speech processor license: ' + name)
    speech_metadata = json.loads((speech / 'runtime-build.json').read_text())
    if (speech_metadata.get('sourceSHA256') != SPEECH_SOURCE_SHA
            or speech_metadata.get('webrtcVersion') != '2.1'
            or speech_metadata.get('abseilVersion') != '20240722.0'
            or speech_metadata.get('wrapperSHA256') != digest(Path(__file__).resolve().parent / 'native/LibreReverseSpeech.cpp')):
        raise ValueError('Unexpected speech runtime provenance')
    print(f"Validated {len(binaries)} native binaries and {len(MODEL_HASHES)} models")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--bundle-from", nargs=2, type=Path, metavar=("MAIN", "WHISPER"))
    args = parser.parse_args()
    try:
        app = args.app.resolve()
        if args.bundle_from:
            bundle_dependencies(app, *args.bundle_from)
        validate(app)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Bundle check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
