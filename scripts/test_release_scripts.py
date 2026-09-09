#!/usr/bin/env python3
"""Offline release-manifest and test-routing regressions; no signing identity needed."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class TestRoutingTests(unittest.TestCase):
    def testConcurrentPCMExportStaysInMediaIntegrationSuite(self):
        text = (SCRIPTS / 'test.sh').read_text()
        pattern = re.search(r"^integration_pattern='([^']+)'", text, re.MULTILINE).group(1)
        self.assertRegex('MeetingTranscriptionTests/testConcurrentPCMExportsOwnDistinctIntermediatePaths', pattern)
        self.assertRegex('MeetingTranscriptionTests/testNormalizedPCMExportSurvivesCancellationAndRestart', pattern)
        self.assertIsNone(re.search(pattern, 'MeetingTranscriptionTests/testNativeExportCancellationDrainsBeforeCleanupAndReplacement'))


class SignedManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='librereverse-manifest-tests-')
        cls.root = Path(cls.workspace.name)
        cls.executable = cls.root / 'sign-manifest'
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(cls.root / 'module-cache'),
                        str(SCRIPTS / 'make_signed_update_manifest.swift'), '-o', str(cls.executable)],
                       check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def invoke(self, download='https://example.com/app.zip', digest='ab' * 32,
               version='1.0', notes=None, key=False):
        output = self.root / 'manifest.json'
        output.unlink(missing_ok=True)
        environment = dict(os.environ)
        environment.pop('LIBREREVERSE_UPDATE_PRIVATE_KEY', None)
        if key:
            # Ephemeral test-only key. Never read a maintainer's signing secret.
            environment['LIBREREVERSE_UPDATE_PRIVATE_KEY'] = base64.b64encode(os.urandom(32)).decode()
            self.disposable_key = environment['LIBREREVERSE_UPDATE_PRIVATE_KEY']
        arguments = [str(self.executable), version, '1', download, digest, str(output)]
        if notes is not None:
            arguments.append(notes)
        result = subprocess.run(arguments, env=environment, text=True, capture_output=True)
        return result, output

    def testRejectsHostlessCredentialedAndNonHTTPSURLsBeforeSigning(self):
        for url in ('https:missing-host', 'http://example.com/app.zip', 'https://user:secret@example.com/app.zip'):
            with self.subTest(url=url):
                result, output = self.invoke(download=url)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('DOWNLOAD_URL', result.stderr)
                self.assertNotIn('user:secret', result.stderr)
                self.assertFalse(output.exists())
        result, output = self.invoke(notes='https:missing-host')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('RELEASE_NOTES_URL', result.stderr)
        self.assertFalse(output.exists())

    def testRejectsEmptyVersionAndNonASCIIHash(self):
        for kwargs, message in [({'version': '  '}, 'VERSION'), ({'digest': 'Ａ' * 64}, 'SHA256')]:
            result, output = self.invoke(**kwargs)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            self.assertFalse(output.exists())

    def testProducesEnvelopeWithDisposableKeyAndNeverPrintsPrivateKey(self):
        result, output = self.invoke(key=True, notes='https://example.com/releases')
        self.assertEqual(result.returncode, 0, result.stderr)
        envelope = json.loads(output.read_text())
        payload = json.loads(base64.b64decode(envelope['payload']))
        self.assertEqual(payload['downloadURL'], 'https://example.com/app.zip')
        self.assertEqual(payload['sha256'], 'ab' * 32)
        self.assertEqual(payload['build'], 1)
        self.assertEqual(len(base64.b64decode(envelope['signature'])), 64)
        self.assertNotIn(self.disposable_key, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
