#!/bin/zsh
# PROTOTYPE — throwaway. Builds and launches the chat scroll prototype on the iPhone simulator.
set -e
cd "$(dirname "$0")"
DEVICE="${1:-iPhone 17}"
SIM_UI="$(find /Applications/Xcode.app/Contents/Applications -maxdepth 1 \( -name 'Simulator.app' -o -name 'DeviceHub.app' \) | head -1)"

xcodegen generate
xcodebuild -project ChatScroll.xcodeproj -scheme ChatScroll \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath build -quiet build

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
[ -n "$SIM_UI" ] && open "$SIM_UI"
xcrun simctl install "$DEVICE" build/Build/Products/Debug-iphonesimulator/ChatScroll.app
xcrun simctl launch "$DEVICE" com.bwees.zulu.chatscroll
