#!/usr/bin/env python3
"""Offline tests for bundle dependency parsing and resolution."""
from pathlib import Path
import json
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import check_bundle


class BundleParserTests(unittest.TestCase):
    def testDependenciesPreserveSpacesAndDeduplicateUniversalSlices(self):
        listing = '''/tmp/App (architecture arm64):
\t/opt/homebrew/lib/libcrypto.4.dylib (compatibility version 4.0.0, current version 4.0.0)
\t@loader_path/../Frameworks/library with spaces.dylib (compatibility version 1.0.0, current version 1.2.0)
/tmp/App (architecture x86_64):
\t/opt/homebrew/lib/libcrypto.4.dylib (compatibility version 4.0.0, current version 4.0.0)
'''
        self.assertEqual(check_bundle.dependencies(listing), [
            '/opt/homebrew/lib/libcrypto.4.dylib',
            '@loader_path/../Frameworks/library with spaces.dylib',
        ])

    def testParsesBothDeploymentLoadCommandsAndRpaths(self):
        listing = '''Load command 1
          cmd LC_RPATH
      cmdsize 48
         path @loader_path/../Frameworks (offset 12)
Load command 2
          cmd LC_BUILD_VERSION
        minos 26.0
          sdk 26.1
Load command 3
          cmd LC_VERSION_MIN_MACOSX
      version 13.3
          sdk 14.0
'''
        self.assertEqual(check_bundle.load_commands(listing), (
            ['@loader_path/../Frameworks'], ['26.0', '13.3']
        ))
        self.assertEqual(check_bundle.version_tuple('26'), check_bundle.version_tuple('26.0.0'))

    def testRpathResolvesUsingOriginalLoaderAndInheritedExecutablePaths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            lib = root / 'lib/libdependency.dylib'
            lib.parent.mkdir()
            lib.write_bytes(b'fixture')
            with patch.object(check_bundle, 'run', return_value=''):
                resolved = check_bundle.resolve_dependency(
                    '@rpath/libdependency.dylib', root / 'lib/owner.dylib',
                    root / 'bin/App', ['@executable_path/../lib']
                )
            self.assertEqual(resolved, lib.resolve())

    def testUnresolvedDependencyFailsInsteadOfGuessingHomebrewPath(self):
        with patch.object(check_bundle, 'run', return_value=''):
            with self.assertRaisesRegex(ValueError, 'Unresolved dependency'):
                check_bundle.resolve_dependency(
                    '@rpath/missing.dylib', Path('/tmp/owner'), Path('/tmp/app')
                )

    def testSystemSwiftRpathCannotHideMissingThirdPartyDependency(self):
        with patch.object(check_bundle, 'run', return_value=''):
            with self.assertRaisesRegex(ValueError, 'Unresolved dependency'):
                check_bundle.resolve_dependency(
                    '@rpath/libsqlcipher-missing.dylib', Path('/tmp/owner'),
                    Path('/tmp/app'), ['/usr/lib/swift']
                )
            self.assertEqual(check_bundle.resolve_dependency(
                '@rpath/libswiftCore.dylib', Path('/tmp/owner'),
                Path('/tmp/app'), ['/usr/lib/swift']
            ), Path('/usr/lib/swift/libswiftCore.dylib'))

    def testRuntimeManifestBindsHelperAndRejectsNativeOptimization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'bin').mkdir()
            helper = root / 'bin/whisper-cli'
            helper.write_bytes(b'helper')
            patch_file = root / 'patch'
            patch_file.write_bytes(b'patch')
            manifest = {
                'sourceRevision': check_bundle.WHISPER_REVISION,
                'patchSHA256': check_bundle.digest(patch_file),
                'helperSHA256': check_bundle.digest(helper),
                'ggmlNative': False,
                'armArchitecture': 'armv8-a',
            }
            metadata = root / 'runtime-build.json'
            with patch.object(check_bundle, 'MODEL_HASHES', {}):
                metadata.write_text(json.dumps(manifest))
                check_bundle.verify_runtime(root, patch_file)
                helper.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'provenance or CPU baseline'):
                    check_bundle.verify_runtime(root, patch_file)
                helper.write_bytes(b'helper')
                manifest['ggmlNative'] = True
                metadata.write_text(json.dumps(manifest))
                with self.assertRaisesRegex(ValueError, 'provenance or CPU baseline'):
                    check_bundle.verify_runtime(root, patch_file)

    def testDependencyBundlingCopiesAndRewritesTransitiveCryptoLibrary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / 'native'
            source.mkdir()
            main, helper, sqlcipher, crypto = [source / name for name in
                ['main', 'whisper-cli', 'libsqlcipher.dylib', 'libcrypto.4.dylib']]
            for file in [main, helper, sqlcipher, crypto]:
                file.write_bytes(file.name.encode())
            app = root / 'LibreReverse.app'
            for relative in ['Contents/MacOS', 'Contents/Resources/Transcription']:
                (app / relative).mkdir(parents=True)
            imports = {main: [str(sqlcipher)], helper: [], sqlcipher: [str(crypto)], crypto: ['/usr/lib/libSystem.B.dylib']}
            calls = []
            def fake_run(*args):
                calls.append(args)
                if args[0] == 'install_name_tool':
                    return ''
                file = args[-1]
                if args[1] == '-l':
                    return ''
                if args[1] == '-D':
                    return str(file) + ':\n' + (str(file) if file.suffix == '.dylib' else '')
                values = ([str(file)] if file.suffix == '.dylib' else []) + imports[file]
                return str(file) + ':\n' + ''.join('\t' + value + ' (compatibility version 1.0.0, current version 1.0.0)\n' for value in values)
            with patch.object(check_bundle, 'run', side_effect=fake_run):
                check_bundle.bundle_dependencies(app, main, helper)
            frameworks = app / 'Contents/Frameworks'
            self.assertEqual((frameworks / crypto.name).read_bytes(), crypto.name.encode())
            self.assertIn(('install_name_tool', '-change', str(crypto), '@loader_path/libcrypto.4.dylib', frameworks / sqlcipher.name), calls)
            self.assertIn(('install_name_tool', '-change', str(sqlcipher), '@loader_path/../Frameworks/libsqlcipher.dylib', app / 'Contents/MacOS/LibreReverse'), calls)

    def testRequiredThirdPartyLicensesRejectMissingEmptyAndExternalFiles(self):
        with tempfile.TemporaryDirectory() as directory:
            contents = Path(directory) / 'Contents'
            licenses = contents / 'Resources/Licenses'
            licenses.mkdir(parents=True)
            for name in check_bundle.THIRD_PARTY_LICENSES:
                (licenses / name).write_text('license fixture')
            check_bundle.verify_third_party_licenses(contents)
            for name in check_bundle.THIRD_PARTY_LICENSES:
                path = licenses / name
                path.unlink()
                with self.assertRaisesRegex(ValueError, name):
                    check_bundle.verify_third_party_licenses(contents)
                path.write_text(' \n')
                with self.assertRaisesRegex(ValueError, name):
                    check_bundle.verify_third_party_licenses(contents)
                path.unlink()
                external = Path(directory) / 'external'
                external.write_text('license outside bundle')
                path.symlink_to(external)
                with self.assertRaisesRegex(ValueError, name):
                    check_bundle.verify_third_party_licenses(contents)
                path.unlink()
                path.write_text('license fixture')

    def testEveryBundleRequiresNonemptyLocalFPNGLicense(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'LibreReverse.app'
            contents = app / 'Contents'
            for relative in ['MacOS', 'Frameworks', 'Resources/Transcription']:
                (contents / relative).mkdir(parents=True)
            (contents / 'Resources/Licenses').mkdir()
            for name in check_bundle.THIRD_PARTY_LICENSES:
                (contents / 'Resources/Licenses' / name).write_text('license fixture')
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'LibreReverse', 'LSMinimumSystemVersion': '26.0',
            }))
            (contents / 'MacOS/LibreReverse').write_bytes(b'main')
            (contents / 'Resources/Transcription/whisper-cli').write_bytes(b'helper')
            (contents / 'Resources/Transcription/WHISPER_CPP_LICENSE.txt').write_text('whisper license')
            patch_file = Path(check_bundle.__file__).resolve().parent / 'patches/whisper-cli-vad-token-clock.patch'
            (contents / 'Resources/Transcription/runtime-build.json').write_text(json.dumps({
                'sourceRevision': check_bundle.WHISPER_REVISION,
                'ggmlNative': False,
                'armArchitecture': 'armv8-a',
                'patchSHA256': check_bundle.digest(patch_file),
            }))
            def fake_run(*args):
                if args[0] == 'lipo':
                    return 'arm64'
                if args[1] == '-l':
                    return 'cmd LC_BUILD_VERSION\nminos 26.0\n'
                return str(args[-1]) + ':\n'
            license_file = contents / 'Resources/FPNG_LICENSE.txt'
            with patch.object(check_bundle, 'MODEL_HASHES', {}), patch.object(check_bundle, 'run', side_effect=fake_run):
                # No aggregate THIRD_PARTY_NOTICES is present in this developer fixture.
                with self.assertRaisesRegex(ValueError, 'FPNG license'):
                    check_bundle.validate(app)
                license_file.write_text('  \n')
                with self.assertRaisesRegex(ValueError, 'FPNG license'):
                    check_bundle.validate(app)
                license_file.unlink()
                outside_license = Path(directory) / 'outside-license'
                outside_license.write_text('license outside bundle')
                license_file.symlink_to(outside_license)
                with self.assertRaisesRegex(ValueError, 'FPNG license'):
                    check_bundle.validate(app)
                license_file.unlink()
                vendor_license = Path(check_bundle.__file__).resolve().parents[1] / 'Sources/CFPNG/vendor/UNLICENSE'
                license_file.write_bytes(vendor_license.read_bytes())
                with self.assertRaisesRegex(ValueError, 'WebRTC microphone processor'):
                    check_bundle.validate(app)
                (contents / 'Frameworks/libLibreReverseSpeech.dylib').write_bytes(b'speech')
                speech = contents / 'Resources/Speech'
                speech.mkdir()
                for name in check_bundle.SPEECH_LICENSES:
                    (speech / name).write_text('upstream license')
                wrapper = Path(check_bundle.__file__).resolve().parent / 'native/LibreReverseSpeech.cpp'
                (speech / 'runtime-build.json').write_text(json.dumps({
                    'sourceSHA256': check_bundle.SPEECH_SOURCE_SHA,
                    'webrtcVersion': '2.1', 'abseilVersion': '20240722.0',
                    'wrapperSHA256': check_bundle.digest(wrapper),
                }))
                check_bundle.validate(app)
                (speech / 'WEBRTC_LICENSE.txt').write_text('')
                with self.assertRaisesRegex(ValueError, 'speech processor license'):
                    check_bundle.validate(app)

    def testOnlyAppleSystemLocationsAreExempt(self):
        self.assertTrue(check_bundle.is_system('/usr/lib/libSystem.B.dylib'))
        self.assertTrue(check_bundle.is_system('/System/Library/Frameworks/AppKit.framework/AppKit'))
        self.assertFalse(check_bundle.is_system('/usr/local/lib/libcrypto.dylib'))
        self.assertFalse(check_bundle.is_system('/opt/homebrew/lib/libcrypto.dylib'))
        self.assertFalse(check_bundle.is_system('/usr/library/libfake.dylib'))


if __name__ == '__main__':
    unittest.main()
