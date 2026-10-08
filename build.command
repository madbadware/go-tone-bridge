#!/bin/zsh
set -eu
cd "${0:A:h}"
TASK_ARCHS=("$(uname -m)")
if (( $# > 0 )); then
  if (( $# != 1 )) || [[ "$1" != '--universal' ]]; then
    print -u2 'Usage: ./build.command [--universal]'
    exit 1
  fi
  TASK_ARCHS=(arm64 x86_64)
fi
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  print 'Install Apple’s Command Line Tools with: xcode-select --install'
  exit 1
fi
TASK_APP='dist/GO Tone Bridge.app'
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources" .build/module-cache
TASK_BINARIES=()
for TASK_ARCH in "${TASK_ARCHS[@]}"; do
  TASK_BINARY=".build/GO-Tone-Bridge-$TASK_ARCH"
  /usr/bin/xcrun swiftc -swift-version 5 -O -module-cache-path "$PWD/.build/module-cache" \
    -target "$TASK_ARCH-apple-macosx13.0" Sources/*.swift Tests/SelfTests.swift \
    -o "$TASK_BINARY"
  TASK_BINARIES+=("$TASK_BINARY")
done
if (( ${#TASK_BINARIES[@]} == 1 )); then
  cp "${TASK_BINARIES[1]}" "$TASK_APP/Contents/MacOS/GO Tone Bridge"
else
  /usr/bin/lipo -create "${TASK_BINARIES[@]}" -output "$TASK_APP/Contents/MacOS/GO Tone Bridge"
fi
cp Resources/* "$TASK_APP/Contents/Resources/"
TASK_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
/usr/bin/sed "s/__APP_VERSION__/$TASK_VERSION/g" Resources/Usage.html > "$TASK_APP/Contents/Resources/Usage.html"
cp LICENSE "$TASK_APP/Contents/Resources/"
cp Info.plist "$TASK_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$TASK_APP"
"$TASK_APP/Contents/MacOS/GO Tone Bridge" --self-test
/usr/bin/codesign --verify --deep --strict "$TASK_APP"
print "Built: $PWD/$TASK_APP"
if (( ${#TASK_ARCHS[@]} == 2 )); then
  /usr/bin/ditto -c -k --norsrc --keepParent "$TASK_APP" dist/GO-Tone-Bridge-macOS-universal.zip
  (cd dist && /usr/bin/shasum -a 256 GO-Tone-Bridge-macOS-universal.zip > SHA256SUMS)
  print "Packaged: $PWD/dist/GO-Tone-Bridge-macOS-universal.zip"
fi
