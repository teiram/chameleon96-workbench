#!/bin/sh
# Remove all generated artifacts (the buildroot output dir under build/)
# but keep the download cache (buildroot/dl) so the next build reuses it.
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)

rm -rf "$ROOT/build"
echo "Cleaned build artifacts under $ROOT/build (download cache kept)."