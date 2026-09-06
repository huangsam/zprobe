#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPS_DIR="$REPO_ROOT/deps/sqlite"

CURRENT_VER="unknown"
if [ -f "$DEPS_DIR/sqlite3.h" ]; then
    CURRENT_VER=$(grep -E '#define SQLITE_VERSION ' "$DEPS_DIR/sqlite3.h" | awk -F'"' '{print $2}')
fi

TARGET_VER=""
YEAR=""
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE=true
            ;;
        --help|-h)
            echo "Usage: $0 <version> [year] [--force]"
            echo "Currently installed SQLite: $CURRENT_VER"
            echo "Example: $0 3.53.4"
            exit 0
            ;;
        *)
            if [ -z "$TARGET_VER" ]; then
                TARGET_VER="$arg"
            elif [ -z "$YEAR" ]; then
                YEAR="$arg"
            else
                echo "Error: Unexpected argument '$arg'" >&2
                exit 1
            fi
            ;;
    esac
done

if [ -z "$TARGET_VER" ]; then
    echo "Error: SQLite version must be explicitly specified." >&2
    echo "Currently installed SQLite: $CURRENT_VER" >&2
    echo "Usage: $0 <version> [year] [--force]" >&2
    echo "Example: $0 3.53.4" >&2
    exit 1
fi

if [ "$CURRENT_VER" = "$TARGET_VER" ] && [ "$FORCE" = false ]; then
    echo "SQLite is already at version $TARGET_VER. Nothing to do (use --force to re-download)."
    exit 0
fi

if [ -z "$YEAR" ]; then
    YEAR=$(date +%Y)
fi

# Calculate 7-digit code: X.Y.Z -> 3XXYY00
IFS='.' read -r MAJOR MINOR PATCH <<< "$TARGET_VER"
if [ -z "$MAJOR" ] || [ -z "$MINOR" ] || [ -z "$PATCH" ]; then
    echo "Error: Invalid version format '$TARGET_VER'. Expected format: X.Y.Z (e.g. 3.53.4)" >&2
    exit 1
fi
CODE=$(printf "%d%02d%02d00" "$MAJOR" "$MINOR" "$PATCH")
URL="https://sqlite.org/${YEAR}/sqlite-amalgamation-${CODE}.zip"

echo "Updating SQLite: $CURRENT_VER -> $TARGET_VER ($URL)..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if ! curl -fSL "$URL" -o "$TMP_DIR/amalgamation.zip"; then
    echo "Error: Failed to download from $URL" >&2
    exit 1
fi

unzip -q "$TMP_DIR/amalgamation.zip" -d "$TMP_DIR"

EXTRACTED_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "sqlite-amalgamation-*" | head -n 1)
if [ -z "$EXTRACTED_DIR" ] || [ ! -d "$EXTRACTED_DIR" ]; then
    echo "Error: Could not find extracted amalgamation directory" >&2
    exit 1
fi

mkdir -p "$DEPS_DIR"
cp "$EXTRACTED_DIR"/{sqlite3.c,sqlite3.h,sqlite3ext.h,shell.c} "$DEPS_DIR/"

NEW_VER=$(grep -E '#define SQLITE_VERSION ' "$DEPS_DIR/sqlite3.h" | awk -F'"' '{print $2}')
echo "Successfully updated deps/sqlite to SQLite $NEW_VER."
