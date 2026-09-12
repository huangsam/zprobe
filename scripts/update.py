#!/usr/bin/env python3

import argparse
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SQLITE_DIR = ROOT / "deps" / "sqlite"
VENDOR_DIR = ROOT / "src" / "web" / "js" / "vendor"

DEFAULT_SQLITE_VERSION = "3.53.4"
DEFAULT_LUCIDE_VERSION = "1.45.0"
DEFAULT_CHART_VERSION = "4.5.1"


def current_sqlite_version() -> str:
    header = SQLITE_DIR / "sqlite3.h"
    if not header.exists():
        return "unknown"
    text = header.read_text(encoding="utf-8", errors="ignore")
    match = re.search(r'#define\s+SQLITE_VERSION\s+"([^"]+)"', text)
    return match.group(1) if match else "unknown"


def require_version(version: str, label: str) -> str:
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError(f"Invalid {label} version '{version}'. Expected format: X.Y.Z")
    return version


def sqlite_code(version: str) -> str:
    # SQLite uses a compact archive naming convention: X.Y.Z -> 3XXYY00,
    # where the patch is zero-padded and an extra 00 is appended.
    # e.g. 3.53.4 becomes 3530400, which matches sqlite-amalgamation-3530400.zip.
    major, minor, patch = version.split(".")
    return f"{int(major)}{int(minor):02d}{int(patch):02d}00"


def download_url(url: str, destination: Path) -> None:
    with urllib.request.urlopen(url) as response, open(destination, "wb") as handle:
        shutil.copyfileobj(response, handle)


def sqlite_update(version: str, year: str | None = None, force: bool = False) -> int:
    version = require_version(version, "SQLite")
    current = current_sqlite_version()
    if current == version and not force:
        print(f"SQLite is already at version {version}. Nothing to do (use --force to re-download).")
        return 0

    year_value = year or str(datetime.now(UTC).year)
    url = f"https://sqlite.org/{year_value}/sqlite-amalgamation-{sqlite_code(version)}.zip"
    print(f"Updating SQLite: {current} -> {version} ({url})...")

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_path = Path(tmpdir)
        archive = tmp_path / "sqlite-amalgamation.zip"
        download_url(url, archive)

        with zipfile.ZipFile(archive) as zf:
            zf.extractall(tmp_path)

        extracted = next(
            (p for p in tmp_path.iterdir() if p.is_dir() and p.name.startswith("sqlite-amalgamation-")),
            None,
        )
        if extracted is None:
            raise RuntimeError("Could not find extracted SQLite amalgamation directory")

        SQLITE_DIR.mkdir(parents=True, exist_ok=True)
        for name in ("sqlite3.c", "sqlite3.h", "sqlite3ext.h", "shell.c"):
            source = extracted / name
            if not source.exists():
                raise FileNotFoundError(f"Missing expected SQLite source file: {source.name}")
            shutil.copy2(source, SQLITE_DIR / name)

    new_version = current_sqlite_version()
    print(f"Successfully updated deps/sqlite to SQLite {new_version}.")
    return 0


def fetch_vendor_asset(name: str, version: str, url: str) -> None:
    # These vendored assets are pinned to specific package tarball layouts from the CDN.
    # If a library changes its bundled file paths, this script must be updated alongside it.
    VENDOR_DIR.mkdir(parents=True, exist_ok=True)
    target = VENDOR_DIR / name
    print(f"Updating {name} to {version} from {url}...")
    download_url(url, target)
    print(f"Saved {target}")


def vendor_update(lucide_version: str, chart_version: str) -> int:
    lucide_version = require_version(lucide_version, "Lucide")
    chart_version = require_version(chart_version, "Chart")

    fetch_vendor_asset(
        "lucide.min.js",
        lucide_version,
        f"https://cdn.jsdelivr.net/npm/lucide@{lucide_version}/dist/umd/lucide.min.js",
    )
    fetch_vendor_asset(
        "chart.umd.js",
        chart_version,
        f"https://cdn.jsdelivr.net/npm/chart.js@{chart_version}/dist/chart.umd.js",
    )
    print("Frontend vendored dependencies updated successfully.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Update vendored project dependencies for zprobe.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    sqlite_parser = subparsers.add_parser("sqlite", help="Update the bundled SQLite amalgamation.")
    sqlite_parser.add_argument("--version", default=DEFAULT_SQLITE_VERSION, help=f"SQLite version to install (default: {DEFAULT_SQLITE_VERSION})")
    sqlite_parser.add_argument("--year", help="SQLite release year (defaults to current year)")
    sqlite_parser.add_argument("--force", action="store_true", help="Re-download even if the version already matches")

    vendor_parser = subparsers.add_parser("vendor", help="Update bundled frontend JS assets.")
    vendor_parser.add_argument("--lucide", default=DEFAULT_LUCIDE_VERSION, help=f"Lucide version to install (default: {DEFAULT_LUCIDE_VERSION})")
    vendor_parser.add_argument("--chart", default=DEFAULT_CHART_VERSION, help=f"Chart.js version to install (default: {DEFAULT_CHART_VERSION})")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "sqlite":
            return sqlite_update(args.version, args.year, args.force)
        if args.command == "vendor":
            return vendor_update(args.lucide, args.chart)
        parser.error(f"Unknown command: {args.command}")
    except (
        OSError,
        ValueError,
        RuntimeError,
        FileNotFoundError,
        urllib.error.URLError,
        zipfile.BadZipFile,
    ) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
