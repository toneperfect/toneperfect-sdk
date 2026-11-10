"""Fails unless every client and manifest states the same version. Run: python3 testing/check_versions.py"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = {
    "python/pyproject.toml": r'^version = "([^"]+)"',
    "python/src/toneperfect.py": r'^__version__ = "([^"]+)"',
    "node/index.cjs": r"^const VERSION = '([^']+)'",
    "dart/pubspec.yaml": r"^version: (\S+)",
    "dart/lib/toneperfect.dart": r"^const String toneperfectVersion = '([^']+)'",
    "ruby/lib/toneperfect.rb": r'^\s*VERSION = "([^"]+)"',
    "php/src/TonePerfect.php": r"^const VERSION = '([^']+)'",
    "go/toneperfect.go": r'^const Version = "([^"]+)"',
}
found = {path: re.search(pattern, open(os.path.join(ROOT, path), encoding="utf-8").read(), re.M).group(1) for path, pattern in SOURCES.items()}
found["node/package.json"] = json.load(open(os.path.join(ROOT, "node/package.json")))["version"]
versions = set(found.values())
for path, version in sorted(found.items()):
    print(f"{version:8} {path}")
sys.exit(0 if len(versions) == 1 else f"versions differ: {sorted(versions)}")
