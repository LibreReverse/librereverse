#!/usr/bin/env python3
"""Read-only verification of reviewed release toolchain and native inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

OVERRIDE_VARIABLES = (
    'SWIFT_EXEC', 'SWIFT_EXEC_MANIFEST', 'TOOLCHAINS',
    'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'DYLD_LIBRARY_PATH', 'DYLD_FRAMEWORK_PATH',
)


def run(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.DEVNULL).strip()


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def override_errors(environment, sdk):
    errors = [f'Unreviewed compiler/linker override is set: {name}'
              for name in OVERRIDE_VARIABLES if environment.get(name)]
    sdk = sdk.resolve()
    if environment.get('SDKROOT') and Path(environment['SDKROOT']).resolve() != sdk:
        errors.append('SDKROOT differs from the verified selected SDK')
    permitted = {
        'CPATH': {sdk / 'usr/include'},
        'C_INCLUDE_PATH': {sdk / 'usr/include'},
        'CPLUS_INCLUDE_PATH': {sdk / 'usr/include', sdk / 'usr/include/c++/v1'},
        'LIBRARY_PATH': {sdk / 'usr/lib'},
    }
    for name, allowed in permitted.items():
        paths = {Path(value).resolve() for value in environment.get(name, '').split(':') if value}
        if not paths.issubset(allowed):
            errors.append(f'{name} includes a search path outside the verified SDK')
    return errors


def host_snapshot(lock):
    prefix = Path(run('brew', '--prefix'))
    snapshot = {
        'architecture': platform.machine(),
        'homebrewPrefix': str(prefix),
        'toolchain': {
            'xcode': run('xcodebuild', '-version'),
            'swift': run('swift', '--version').splitlines()[0],
            'clang': run('xcrun', 'clang', '--version').splitlines()[0],
            'sdkVersion': run('xcrun', '--show-sdk-version'),
            'sdkBuild': run('xcrun', '--show-sdk-build-version'),
        },
        'pkgConfig': {
            'prefix': run('pkg-config', '--variable=prefix', 'sqlcipher'),
            'cflags': run('pkg-config', '--cflags', 'sqlcipher'),
            'libs': run('pkg-config', '--libs', 'sqlcipher'),
        },
        'packages': {},
    }
    for package in lock['packages']:
        root = Path(run('brew', '--prefix', package['name'])).resolve()
        receipt = json.loads((root / 'INSTALL_RECEIPT.json').read_text())
        snapshot['packages'][package['name']] = {
            'version': receipt['source']['versions']['stable'],
            'architecture': receipt['arch'],
            'pouredFromBottle': receipt['poured_from_bottle'],
            'installedFiles': {path: digest(root / path) for path in package['installedFiles']},
            'runtimeDependencies': {
                dep['full_name']: dep['pkg_version'] for dep in receipt['runtime_dependencies']
                if dep['full_name'] in package['runtimeDependencies']
            },
        }
    return snapshot


def compare_snapshot(lock, snapshot):
    errors = []
    for key in ['architecture', 'homebrewPrefix', 'toolchain', 'pkgConfig']:
        if snapshot.get(key) != lock[key]:
            errors.append(f'{key} differs from the reviewed release lock')
    for package in lock['packages']:
        installed = snapshot.get('packages', {}).get(package['name'], {})
        for key in ['version', 'architecture', 'pouredFromBottle', 'runtimeDependencies']:
            if installed.get(key) != package[key]:
                errors.append(f'{package["name"]}: {key} differs from release lock')
        for path, expected in package['installedFiles'].items():
            if installed.get('installedFiles', {}).get(path) != expected:
                errors.append(f'{package["name"]}/{path}: installed input hash differs')
    return errors


def verify_bottles(lock, directory):
    errors = []
    for package in lock['packages']:
        bottle = package['bottle']
        candidates = [directory / bottle['filename']]
        candidates += sorted(directory.glob('*--' + bottle['filename']))
        file = next((candidate for candidate in candidates if candidate.is_file()), None)
        if file is None:
            errors.append(f'{bottle["filename"]}: locked bottle missing')
        elif digest(file) != bottle['sha256']:
            errors.append(f'{bottle["filename"]}: bottle SHA-256 mismatch')
    return errors


def verify_bundle_manifest(lock, app):
    manifest = json.loads((app / 'Contents/Resources/native-dependencies.json').read_text())
    expected = sorted(
        (item['file'], item['sourceSHA256'])
        for package in lock['packages'] for item in package['packagedLibraries']
    )
    actual = sorted((item['file'], item['sourceSHA256']) for item in manifest)
    return [] if actual == expected else ['packaged native dependency closure differs from release lock']


def verify_runtime_toolchain(lock, runtime):
    manifest = json.loads((runtime / 'runtime-build.json').read_text())
    compiler = manifest.get('compiler', '').splitlines()
    if (not compiler or compiler[0] != lock['toolchain']['clang']
            or manifest.get('sdkVersion') != lock['toolchain']['sdkVersion']):
        return ['native speech helper was prepared with a different compiler or SDK']
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', type=Path, default=Path(__file__).resolve().parent.parent / 'release/release-inputs.json')
    parser.add_argument('--bottles', type=Path, help='also verify exact cached/downloaded bottle archives')
    parser.add_argument('--bottles-only', action='store_true', help='verify bottle archives before provisioning, without requiring installed build tools')
    parser.add_argument('--bundle', type=Path, help='also verify the packaged non-system dependency closure')
    parser.add_argument('--runtime', type=Path, help='also verify the native helper compiler and SDK')
    args = parser.parse_args()
    if args.bottles_only and (args.bottles is None or args.bundle or args.runtime):
        parser.error('--bottles-only requires --bottles and cannot be combined with --bundle or --runtime')
    try:
        lock = json.loads(args.lock.read_text())
        if lock.get('schemaVersion') != 1:
            raise ValueError('unsupported release input lock schema')
        errors = []
        if not args.bottles_only:
            errors += override_errors(os.environ, Path(run('xcrun', '--show-sdk-path')))
            errors += compare_snapshot(lock, host_snapshot(lock))
        if args.bottles:
            errors += verify_bottles(lock, args.bottles)
        if args.bundle:
            errors += verify_bundle_manifest(lock, args.bundle)
        if args.runtime:
            errors += verify_runtime_toolchain(lock, args.runtime)
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            print('Release inputs rejected. Provision the locked inputs or review an explicit lock update.', file=sys.stderr)
            return 1
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Release input verification failed: {error}', file=sys.stderr)
        return 1
    print('Bottle archives match the reviewed lock' if args.bottles_only else 'Release toolchain and native inputs match the reviewed lock')
    return 0


if __name__ == '__main__':
    sys.exit(main())
