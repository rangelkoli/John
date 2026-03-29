#!/bin/bash

# John - Build and Run Script
# This script builds and launches the John macOS app

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT_FILE="$PROJECT_DIR/John.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build"
APP_PATH="$BUILD_DIR/Build/Products/Debug/John.app"
BACKEND_PORT=8765

stop_backend() {
    echo "Checking for existing backend process..."
    
    # Find and kill any process running on the backend port
    if lsof -Pi :$BACKEND_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo "Stopping existing backend on port $BACKEND_PORT..."
        lsof -Pi :$BACKEND_PORT -sTCP:LISTEN -t | xargs kill -9 2>/dev/null || true
        sleep 1
        
        # Force kill if still running
        if lsof -Pi :$BACKEND_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
            echo "Force killing stubborn process..."
            lsof -Pi :$BACKEND_PORT -sTCP:LISTEN -t | xargs kill -9 2>/dev/null || true
            sleep 1
        fi
        echo "Previous backend stopped."
    else
        echo "No existing backend found on port $BACKEND_PORT."
    fi
}

stop_app() {
    echo "Checking for existing John app..."
    if pgrep -f "John.app" >/dev/null 2>&1; then
        echo "Stopping existing John app..."
        pkill -f "John.app" 2>/dev/null || true
        sleep 1
        echo "Previous app stopped."
    else
        echo "No existing John app found."
    fi
}

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
    
    #Stop existing instances
    stop_backend
    stop_app
    
    echo "🚀 Launching John..."
    
    # Launch the app
    open "$APP_PATH"
    
    echo "✨ John is now running!"
    echo ""
    echo "📋 Quick Tips:"
    echo "   • Press Shift-Command-Space to toggle the panel and focus input"
    echo "   • Hover over the notch to reveal the panel"
    echo "   • Click the brain icon in the menu bar"
    echo "   • Press Cmd+, for Settings (API Key)"
    echo ""
    echo "🔧 To start the Python backend:"
    echo "   ./start-backend.sh"
else
    echo "❌ Build failed - app not found at $APP_PATH"
    exit 1
fi