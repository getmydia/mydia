#!/usr/bin/env bash
set -e

# Build Flutter web player and copy to Phoenix static assets
# This script is used during local development and CI/CD

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PLAYER_DIR="$PROJECT_ROOT/player"
STATIC_DIR="$PROJECT_ROOT/priv/static/player"

# Check if player directory exists
if [ ! -d "$PLAYER_DIR" ]; then
  echo "Error: Flutter player directory not found at $PLAYER_DIR"
  exit 1
fi

echo "Building Flutter web player..."
cd "$PLAYER_DIR"

# Install dependencies
echo "Installing dependencies..."
flutter pub get

# Run code generation
echo "Running code generation..."
flutter pub run build_runner build

# Build web release
echo "Building web release..."
flutter build web \
  --release \
  --base-href /player/ \
  --tree-shake-icons

# Copy to Phoenix static directory
echo "Copying to Phoenix static assets..."
mkdir -p "$STATIC_DIR"
rm -rf "$STATIC_DIR"/*
cp -r build/web/* "$STATIC_DIR/"

echo "✓ Flutter web player built successfully"
echo "  Output: $STATIC_DIR"
