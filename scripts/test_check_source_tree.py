#!/usr/bin/env python3
import unittest
from pathlib import Path
import subprocess
import tempfile
import check_source_tree as checker


class SourceTreeTests(unittest.TestCase):
    def testCandidatesIncludeNewSourceButExcludeIgnoredLocalArtifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / '.gitignore').write_text('ignored/\ntracked.swift\n')
            (root / 'tracked.swift').write_text('tracked source')
            subprocess.run(['git', '-C', str(root), 'add', '-f', 'tracked.swift'], check=True)
            (root / 'new.swift').write_text('new production source')
            (root / 'ignored').mkdir()
            (root / 'ignored/local.key').write_text('local fixture')
            self.assertEqual(checker.source_candidates(root),
                             [b'.gitignore', b'new.swift', b'tracked.swift'])
            (root / 'new.swift').write_bytes(b'ghp_' + b'a' * 36)
            findings = [(name, checker.inspect(name.decode(), (root / name.decode()).read_bytes()))
                        for name in checker.source_candidates(root)]
            self.assertIn((b'new.swift', ['GitHub token']), findings)

    def testGeneratedAndPrivateFilesAreRejected(self):
        for path in ('.artifacts/a.json', 'dist/App.app/Info.plist', 'capture.mp4',
                     'library.db', '.env.local', 'signing.p12', 'screenshot.png'):
            with self.subTest(path=path):
                self.assertTrue(checker.inspect(path, b''))

    def testOrdinarySourceAndIconAreAllowed(self):
        for path in ('Sources/App.swift', 'App/AppIcon.icon/Assets/Icon.png', '.env.example'):
            self.assertEqual(checker.inspect(path, b'ordinary source'), [])

    def testCredentialDetectionDoesNotExemptTestFiles(self):
        token = b'ghp_' + b'a' * 36
        self.assertIn('GitHub token', checker.inspect('Tests/Test.swift', token))
        private_key = b'-----BEGIN ' + b'PRIVATE KEY-----'
        self.assertIn('private key', checker.inspect('test.txt', private_key))

    def testOnlyPublishedAWSExampleIsExempt(self):
        self.assertEqual(checker.inspect('test.swift', checker.PUBLIC_EXAMPLE), [])
        unknown = b'AKIA' + b'Z' * 16
        self.assertIn('AWS access key', checker.inspect('test.swift', unknown))

    def testRenamedBinaryPayloadIsRejected(self):
        self.assertTrue(checker.inspect('fixture.txt', b'SQLite format 3\x00'))

    def testPersonalPathsAreRejectedWithoutBanningPortableHome(self):
        local = b'/Users/' + b'developer/Projects/private/'
        self.assertIn('developer-machine path', checker.inspect('README.md', local))
        self.assertEqual(checker.inspect('README.md', b'~/Library/Application Support/LibreReverse'), [])


if __name__ == '__main__':
    unittest.main()
