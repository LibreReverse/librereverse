#!/usr/bin/env python3
"""Offline regression tests for signed-release input gates."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest

import verify_release_inputs as verifier


class ReleaseInputTests(unittest.TestCase):
    def setUp(self):
        self.lock = {
            'architecture': 'arm64', 'homebrewPrefix': '/opt/homebrew',
            'toolchain': {'xcode': 'Xcode fixture', 'clang': 'clang fixture', 'sdkVersion': '26.5'},
            'pkgConfig': {'prefix': '/opt/homebrew/Cellar/sqlcipher/4.18.0'},
            'packages': [{
                'name': 'sqlcipher', 'version': '4.18.0', 'architecture': 'arm64',
                'pouredFromBottle': True, 'runtimeDependencies': {'openssl@4': '4.0.1'},
                'installedFiles': {'lib/libsqlcipher.dylib': 'reviewed-library-hash'},
                'packagedLibraries': [{'file': 'libsqlcipher.dylib', 'sourceSHA256': 'reviewed-library-hash'}],
                'bottle': {'filename': 'sqlcipher.bottle.tar.gz', 'sha256': ''},
            }],
        }
        self.snapshot = {key: deepcopy(self.lock[key]) for key in ['architecture', 'homebrewPrefix', 'toolchain', 'pkgConfig']}
        self.snapshot['packages'] = {'sqlcipher': deepcopy(self.lock['packages'][0])}

    def testExactSnapshotAccepted(self):
        self.assertEqual(verifier.compare_snapshot(self.lock, self.snapshot), [])

    def testVersionLabelAloneCannotHideDifferentLibrary(self):
        self.snapshot['packages']['sqlcipher']['installedFiles']['lib/libsqlcipher.dylib'] = 'different'
        self.assertTrue(any('hash differs' in error for error in verifier.compare_snapshot(self.lock, self.snapshot)))

    def testCompilerPkgConfigAndCryptoDependencyDriftRejected(self):
        for mutation in ['compiler', 'pkgconfig', 'crypto']:
            snapshot = deepcopy(self.snapshot)
            if mutation == 'compiler':
                snapshot['toolchain']['xcode'] = 'different'
            elif mutation == 'pkgconfig':
                snapshot['pkgConfig']['prefix'] = '/tmp/unreviewed-sqlite'
            else:
                snapshot['packages']['sqlcipher']['runtimeDependencies']['openssl@4'] = '4.0.2'
            self.assertTrue(verifier.compare_snapshot(self.lock, snapshot))

    def testOnlySelectedSDKSearchOverridesAccepted(self):
        sdk = Path('/fixture/SDK').resolve()
        self.assertEqual(verifier.override_errors({
            'SDKROOT': str(sdk), 'CPLUS_INCLUDE_PATH': str(sdk / 'usr/include') + ':',
            'LIBRARY_PATH': str(sdk / 'usr/lib'),
        }, sdk), [])
        self.assertTrue(verifier.override_errors({'CPATH': '/tmp/unreviewed'}, sdk))
        self.assertTrue(verifier.override_errors({'SWIFT_EXEC': '/tmp/swift'}, sdk))

    def testCachedBottleHashAndPackagedClosureAreVerified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bottle = root / 'cachekey--sqlcipher.bottle.tar.gz'
            bottle.write_bytes(b'reviewed-bottle')
            self.lock['packages'][0]['bottle']['sha256'] = verifier.digest(bottle)
            self.assertEqual(verifier.verify_bottles(self.lock, root), [])
            bottle.write_bytes(b'changed')
            self.assertTrue(verifier.verify_bottles(self.lock, root))
            resources = root / 'LibreReverse.app/Contents/Resources'
            resources.mkdir(parents=True)
            manifest = resources / 'native-dependencies.json'
            manifest.write_text(json.dumps(self.lock['packages'][0]['packagedLibraries']))
            self.assertEqual(verifier.verify_bundle_manifest(self.lock, root / 'LibreReverse.app'), [])
            manifest.write_text('[]')
            self.assertTrue(verifier.verify_bundle_manifest(self.lock, root / 'LibreReverse.app'))

    def testNativeHelperCompilerMustMatchAppCompiler(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / 'runtime-build.json'
            manifest.write_text(json.dumps({'compiler': 'clang fixture\nTarget: arm64', 'sdkVersion': '26.5'}))
            self.assertEqual(verifier.verify_runtime_toolchain(self.lock, root), [])
            manifest.write_text(json.dumps({'compiler': 'different', 'sdkVersion': '26.5'}))
            self.assertTrue(verifier.verify_runtime_toolchain(self.lock, root))


if __name__ == '__main__':
    unittest.main()
