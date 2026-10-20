#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p dist/Nightshift.app/Contents/MacOS dist/Nightshift.app/Contents/Resources .build
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/nightshift-clang-cache"
export SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/nightshift-swift-cache"
swiftc -swift-version 5 -O -module-cache-path "$SWIFT_MODULECACHE_PATH" Sources/Core.swift Sources/Integrations.swift Sources/LidCore.swift Sources/LidHelper.swift -o dist/Nightshift.app/Contents/Resources/NightshiftLidHelper -framework IOKit
swiftc -swift-version 5 -O -module-cache-path "$SWIFT_MODULECACHE_PATH" Sources/Core.swift Sources/Integrations.swift Sources/Detection.swift Sources/LidCore.swift Sources/ClosedLid.swift Sources/App.swift Sources/main.swift -o dist/Nightshift.app/Contents/MacOS/Nightshift -framework AppKit -framework IOKit
cp Resources/Info.plist dist/Nightshift.app/Contents/Info.plist
cp Resources/Nightshift.icns dist/Nightshift.app/Contents/Resources/Nightshift.icns
cp Resources/NightshiftIcon.png dist/Nightshift.app/Contents/Resources/NightshiftIcon.png
cp Resources/SETUP.html dist/Nightshift.app/Contents/Resources/SETUP.html
cp scripts/configure-hooks.py dist/Nightshift.app/Contents/Resources/configure-hooks.py
cp scripts/install-lid-helper.sh scripts/uninstall-lid-helper.sh dist/Nightshift.app/Contents/Resources/
codesign --force --sign - dist/Nightshift.app/Contents/Resources/NightshiftLidHelper
codesign --force --sign - dist/Nightshift.app
echo "Built dist/Nightshift.app"
