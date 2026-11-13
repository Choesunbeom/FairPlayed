#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos --find clang++)"
mkdir -p output
"$CXX" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
 -fobjc-arc -fblocks -O2 -I src -dynamiclib \
 -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
 -Wl,-install_name,@rpath/DuoSoloSettings.dylib \
 src/DuoDeskPlayer.mm src/DuoStatusBar.mm src/DuoSoloShim.mm \
 src/DuoKit.m src/DuoDeskPosture.m -o output/DuoSoloSettings.dylib
file output/DuoSoloSettings.dylib
