#!/usr/bin/env bash
# SquishIt — Lambda packaging script
# Run this before deploying to AWS (or let Terraform call it via null_resource)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"

echo "🧹 Cleaning dist/"
rm -rf "$DIST"
mkdir -p "$DIST"

# ── Package: compress Lambda ──────────────────────────────────────────────
echo "📦 Packaging compress Lambda…"
COMPRESS_DIR="$ROOT/compress"
COMPRESS_TMP="$DIST/compress_tmp"

mkdir -p "$COMPRESS_TMP"
cp "$COMPRESS_DIR/lambda_function.py" "$COMPRESS_TMP/"

# Install Pillow into the package
pip install \
  --quiet \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  --target "$COMPRESS_TMP" \
  Pillow==10.3.0

cd "$COMPRESS_TMP"
zip -qr "$DIST/compress_lambda.zip" .
cd "$ROOT"
echo "  ✓ dist/compress_lambda.zip ($(du -sh "$DIST/compress_lambda.zip" | cut -f1))"

# ── Package: api Lambda ───────────────────────────────────────────────────
echo "📦 Packaging api Lambda…"
API_DIR="$ROOT/api"
API_TMP="$DIST/api_tmp"

mkdir -p "$API_TMP"
cp "$API_DIR/lambda_function.py" "$API_TMP/"
# api Lambda only uses boto3 (provided by the runtime)

cd "$API_TMP"
zip -qr "$DIST/api_lambda.zip" .
cd "$ROOT"
echo "  ✓ dist/api_lambda.zip ($(du -sh "$DIST/api_lambda.zip" | cut -f1))"

# ── Cleanup ───────────────────────────────────────────────────────────────
rm -rf "$COMPRESS_TMP" "$API_TMP"

echo ""
echo "✅ Build complete! Zips are in lambda/dist/"
echo "   compress_lambda.zip → squishit-compress function"
echo "   api_lambda.zip      → squishit-api function"
