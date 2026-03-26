#!/bin/bash
# Adds required privacy keys to the app's Info.plist for microphone and speech recognition access.
# Run after `electrobun build`.

PLIST="build/dev-macos-arm64/john-assistant-dev.app/Contents/Info.plist"

if [ ! -f "$PLIST" ]; then
  echo "Info.plist not found at $PLIST — skipping patch"
  exit 0
fi

# Add microphone usage description
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'John Assistant needs microphone access to listen for \"Hey John\" and voice commands.'" "$PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription 'John Assistant needs microphone access to listen for \"Hey John\" and voice commands.'" "$PLIST"

# Add speech recognition usage description
/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string 'John Assistant uses speech recognition to understand your voice commands.'" "$PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :NSSpeechRecognitionUsageDescription 'John Assistant uses speech recognition to understand your voice commands.'" "$PLIST"

echo "Info.plist patched with privacy keys"
