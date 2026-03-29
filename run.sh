#!/bin/bash

# John - Build and Run Script
# This script builds and launches the John macOS app

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT_FILE="$PROJECT_DIR/John.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build"
APP_PATH="$BUILD_DIR/Build/Products/Debug/John.app"

echo "🏗️  Building John..."

# Build the project
xcodebuild -project "$PROJECT_FILE" \
    -scheme John \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    build

# Check if build succeeded
if [ -d "$APP_PATH" ]; then
    echo "✅ Build successful!"
    echo "🚀 Launching John..."
    
    # Kill any existing instance
    pkill -f "John.app" 2>/dev/null || true
    
    # Launch the app
    open "$APP_PATH"
    
    echo "✨ John is now running!"
    echo ""
    echo "📋 Quick Tips:"
    echo "   • Press Shift-Command-Space to toggle the panel and focus input"
    echo "   • Hover over the notch to reveal the panel"
    echo "   • Click the brain icon in the menu bar"
    echo "   • Press Cmd+, for Settings (API Key)"
else
    echo "❌ Build failed - app not found at $APP_PATH"
    exit 1
fi