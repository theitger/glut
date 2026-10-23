#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
app="dist/Glut.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist/AppIcon.iconset

if [[ "${1:-}" == "--native" ]]; then
  swift build -c release
  bin_dir=$(swift build -c release --show-bin-path)
  cp "$bin_dir/Glut" "$app/Contents/MacOS/Glut"
  cp "$bin_dir/GlutHelper" "$app/Contents/Resources/GlutHelper"
else
  for architecture in arm64 x86_64; do
    swift build -c release --triple "$architecture-apple-macosx14.0"
  done
  for executable in Glut GlutHelper; do
    /usr/bin/lipo -create ".build/arm64-apple-macosx/release/$executable" ".build/x86_64-apple-macosx/release/$executable" -output "dist/$executable-universal"
  done
  cp dist/Glut-universal "$app/Contents/MacOS/Glut"
  cp dist/GlutHelper-universal "$app/Contents/Resources/GlutHelper"
fi

swift Scripts/icon.swift dist/AppIcon.iconset
/usr/bin/iconutil -c icns dist/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
chmod 755 "$app/Contents/MacOS/Glut" "$app/Contents/Resources/GlutHelper"
/usr/bin/codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime "$app/Contents/Resources/GlutHelper"
/usr/bin/codesign --force --sign "${SIGNING_IDENTITY:--}" --options runtime "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "dist/Glut-$version.zip"
/usr/bin/shasum -a 256 "dist/Glut-$version.zip"
