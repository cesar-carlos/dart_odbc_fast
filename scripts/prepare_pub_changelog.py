"""Keep the changelog within pub.dev's limit without removing history."""

import argparse
from pathlib import Path
import re

MAX_CONTENT_BYTES = 262144


def compact_changelog(original: str) -> str:
    lines: list[str] = []
    fence: str | None = None
    for line in original.splitlines():
        stripped = line.lstrip()
        if stripped.startswith(('```', '~~~')):
            marker = stripped[:3]
            fence = None if fence == marker else marker
            lines.append(line)
            continue
        continuation = (
            fence is None
            and line.startswith('  ')
            and not line.startswith('   ')
            and stripped
            and not re.match(r'([-+*>#|]|\d+[.)]\s)', stripped)
            and lines
            and lines[-1].strip()
            and not lines[-1].endswith(('  ', '\\'))
            and not lines[-1].lstrip().startswith(('```', '~~~', '|'))
        )
        if continuation:
            lines[-1] += ' ' + stripped
        else:
            lines.append(line)
    compact = '\n'.join(lines) + '\n'
    if original.split() != compact.split():
        raise ValueError('Changelog preparation must only change whitespace')
    return compact


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Validate without writing')
    parser.add_argument(
        '--require-ready', action='store_true',
        help='Require the committed changelog to already fit the content limit',
    )
    args = parser.parse_args()
    path = Path('CHANGELOG.md')
    original = path.read_bytes()
    if args.require_ready and len(original) > MAX_CONTENT_BYTES:
        raise SystemExit(
            'Run python scripts/prepare_pub_changelog.py before committing '
            f'the release: CHANGELOG.md is {len(original)} bytes'
        )
    prepared = original
    if len(original) > MAX_CONTENT_BYTES:
        prepared = compact_changelog(original.decode('utf-8')).encode('utf-8')
    if len(prepared) > MAX_CONTENT_BYTES:
        raise SystemExit(
            f'CHANGELOG.md remains {len(prepared)} bytes after whitespace '
            f'compaction; pub.dev permits {MAX_CONTENT_BYTES}'
        )
    if not args.check and not args.require_ready and prepared != original:
        path.write_bytes(prepared)
    print(f'pub.dev changelog: {len(original)} -> {len(prepared)} bytes')


if __name__ == '__main__':
    main()
