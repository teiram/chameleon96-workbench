#!/bin/sh
# Remove all generated artifacts (the buildroot output dir under build/)
# and the buildroot download cache (buildroot/dl). The buildroot source
# clone is kept; the next build re-fetches all upstream sources.
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)

rm -rf "$ROOT/build"
rm -rf "$ROOT/buildroot/dl"
echo "Cleaned build artifacts and download cache."