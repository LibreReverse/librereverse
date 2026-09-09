#!/usr/bin/env python3
"""Reject generated payloads, local paths and common secrets in tracked and nonignored new source."""
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

GENERATED = {'.build', '.artifacts', 'dist', '__pycache__', '.DS_Store'}
PAYLOADS = {'.mp4', '.mov', '.m4a', '.wav', '.mp3', '.sqlite', '.sqlite3', '.db',
            '.zip', '.dmg', '.pkg', '.dylib', '.o', '.a', '.bin', '.pyc', '.trace',
            '.png', '.jpg', '.jpeg', '.gif', '.webp', '.heic', '.pdf'}
SECRETS = {
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    'AWS access key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'GitHub token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b'),
    'Google OAuth secret': re.compile(rb'\bGOCSPX-[A-Za-z0-9_-]{20,}\b'),
    'Google API key': re.compile(rb'\bAIza[0-9A-Za-z_-]{35}\b'),
    'Slack token': re.compile(rb'\bxox[baprs]-[A-Za-z0-9-]{20,}\b'),
    'API key': re.compile(rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{40,}\b'),
}
# AWS publishes this exact example for signing test vectors; no general test exemption.
PUBLIC_EXAMPLE = b'AKIAIOSFODNN7EXAMPLE'
MACHINE_PATH = re.compile(rb'/Users/[^/\s]+/(?:Projects|Desktop|Downloads)/')


def inspect(path, data):
    p = PurePosixPath(path)
    errors = []
    if any(part in GENERATED or part.endswith('.app') for part in p.parts):
        errors.append('generated output')
    is_icon = path.startswith('App/AppIcon.icon/') and p.suffix.lower() in {'.png', '.icns'}
    binary_magic = data.startswith((b'\x7fELF', b'SQLite format 3\x00', b'\x89PNG', b'%PDF-'))
    if not is_icon and (p.suffix.lower() in PAYLOADS or binary_magic):
        errors.append('binary, recording or database payload')
    if p.name == '.env' or (p.name.startswith('.env.') and p.name != '.env.example') or p.suffix in {'.p12', '.p8', '.pem', '.key'}:
        errors.append('local credential or signing file')
    if MACHINE_PATH.search(data):
        errors.append('developer-machine path')
    for label, pattern in SECRETS.items():
        if any(match.group() != PUBLIC_EXAMPLE for match in pattern.finditer(data)):
            errors.append(label)
    return errors


def source_candidates(root):
    # Include files a maintainer is about to add, while respecting ignored local
    # build outputs. Tracked files remain checked even if now ignored.
    return sorted(set(filter(None, subprocess.check_output([
        'git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z'
    ]).split(b'\0'))))


def main():
    root = Path(__file__).resolve().parent.parent
    names = source_candidates(root)
    errors = []
    count = 0
    for name in filter(None, names):
        path = name.decode('utf-8', errors='surrogateescape')
        file = root / path
        if file.is_symlink():
            errors.append((path, 'source symlink'))
        elif file.is_file():
            count += 1
            errors.extend((path, reason) for reason in inspect(path, file.read_bytes()))
        elif file.exists():
            errors.append((path, 'expected regular file'))
    for path, reason in errors:
        print(f'{path}: {reason}', file=sys.stderr)
    print(f'Checked {count} tracked or nonignored new source files; {len(errors)} issues')
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
