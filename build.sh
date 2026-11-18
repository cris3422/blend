#!/bin/zsh
# Builds build/Blend.app from the Swift sources + web/. Pass --install to also copy it into /Applications.
set -e
cd "${0:A:h}"
APP="build/Blend.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[[ -f build/AppIcon.icns ]] || python3 icon.py
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$APP/Contents/MacOS/Blend" \
  main.swift Library.swift AudioBridge.swift engine/PDEngine.swift engine/PDMixer.swift engine/Separation.swift
cp Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R web "$APP/Contents/Resources/web"
codesign --force --deep -s - "$APP"
echo "built $APP"
if [[ "$1" == "--install" ]]; then
  rm -rf "/Applications/Blend.app"
  cp -R "$APP" "/Applications/Blend.app"
  echo "installed /Applications/Blend.app"
fi
