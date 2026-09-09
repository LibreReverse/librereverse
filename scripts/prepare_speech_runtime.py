#!/usr/bin/env python3
"""Build the standalone, device-independent WebRTC microphone processor."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / '.artifacts/speech'
SOURCE_SHA = 'ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe'
URL = 'https://gstreamer.freedesktop.org/src/mirror/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz'

def digest(path):
    return hashlib.file_digest(path.open('rb'), 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(path.read_bytes()).hexdigest()

def run(*args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)

def main():
    RUNTIME.mkdir(parents=True, exist_ok=True)
    archive = RUNTIME / 'webrtc-audio-processing-2.1.tar.xz'
    if not archive.exists():
        temporary = archive.with_suffix('.download')
        urllib.request.urlretrieve(URL, temporary)
        if digest(temporary) != SOURCE_SHA:
            raise SystemExit('WebRTC source checksum mismatch')
        temporary.replace(archive)
    if digest(archive) != SOURCE_SHA:
        raise SystemExit('WebRTC source checksum mismatch')
    source = RUNTIME / 'webrtc-audio-processing-2.1'
    # Build from clean sources, including the Abseil subproject, rather than
    # accepting edited files or stale objects from a previous experiment.
    for generated in (source, RUNTIME / 'build'):
        if generated.exists():
            shutil.rmtree(generated)
    # Meson verifies Abseil 20240722.0 and its build definitions against the
    # source and patch hashes in the pinned upstream wrap.
    run('tar', '-xf', archive, '-C', RUNTIME)
    tools = RUNTIME / 'tools'
    if not (tools / 'bin/meson').exists():
        run(sys.executable, '-m', 'venv', tools)
        run(tools / 'bin/pip', 'install', 'meson==1.7.2', 'ninja==1.11.1.4')
    env = dict(os.environ, PATH=str(tools / 'bin') + ':' + os.environ['PATH'], MACOSX_DEPLOYMENT_TARGET='26.0')
    build = RUNTIME / 'build'
    args = ['--reconfigure'] if (build / 'meson-private/coredata.dat').exists() else []
    run(tools / 'bin/meson', 'setup', *args, build, source,
        '--buildtype=release', '--default-library=static', '-Db_staticpic=true', env=env)
    run(tools / 'bin/meson', 'compile', '-C', build, '-j', '4', env=env)
    wrapper = ROOT / 'scripts/native/LibreReverseSpeech.cpp'
    output = RUNTIME / 'libLibreReverseSpeech.dylib'
    libraries = sorted(build.rglob('*.a'))
    run('xcrun', 'clang++', '-std=c++17', '-O3', '-DNDEBUG', '-DWEBRTC_POSIX', '-DWEBRTC_MAC',
        '-fvisibility=hidden', '-mmacosx-version-min=26.0', '-dynamiclib',
        '-I' + str(source), '-I' + str(source / 'webrtc'),
        '-I' + str(source / 'subprojects/abseil-cpp-20240722.0'), wrapper,
        *libraries, '-framework', 'Foundation', '-Wl,-dead_strip',
        '-Wl,-install_name,@rpath/libLibreReverseSpeech.dylib', '-o', output, env=env)
    licenses = RUNTIME / 'licenses'
    licenses.mkdir(exist_ok=True)
    for original, name in [(source / 'COPYING', 'WEBRTC_COPYING.txt'),
                           (source / 'webrtc/LICENSE', 'WEBRTC_LICENSE.txt'),
                           (source / 'webrtc/PATENTS', 'WEBRTC_PATENTS.txt'),
                           (source / 'webrtc/third_party/pffft/LICENSE', 'PFFFT_LICENSE.txt'),
                           (source / 'webrtc/third_party/rnnoise/COPYING', 'RNNOISE_COPYING.txt'),
                           (source / 'subprojects/abseil-cpp-20240722.0/LICENSE', 'ABSEIL_LICENSE.txt')]:
        shutil.copyfile(original, licenses / name)
    (RUNTIME / 'runtime-build.json').write_text(json.dumps({
        'webrtcVersion': '2.1', 'sourceSHA256': SOURCE_SHA,
        'abseilVersion': '20240722.0', 'wrapperSHA256': digest(wrapper),
        'librarySHA256': digest(output),
    }, indent=2) + '\n')
    print(output)

if __name__ == '__main__':
    main()
