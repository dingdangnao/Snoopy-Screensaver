#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT="$ROOT/SnoopyTVScreenSaver.xcodeproj"
DERIVED="$ROOT/.build-xcode"
DEST="$HOME/Library/Screen Savers"

if [ "${SNOOPY_SKIP_PROXY_BUILD:-0}" != "1" ]; then
  xcrun swift build --package-path "$ROOT" -c release --product SnoopySequenceProxyBuilder
  "$ROOT/.build/release/SnoopySequenceProxyBuilder" \
    --index "$ROOT/Resources/asset-index.json" \
    --output "$ROOT/.derived-media"
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo "需要完整 Xcode；当前 xcode-select 不是 Xcode。" >&2
    exit 2
  fi
fi

# macOS 26 runs legacyScreenSaver as ARM64E; its module loader performs an
# exact subtype check rather than accepting a generic arm64 slice.
xcodebuild \
  -project "$PROJECT" \
  -scheme SnoopyTVScreenSaver \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64e x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  build

PRODUCT="$DERIVED/Build/Products/Release/Snoopy TV.saver"
if [ ! -d "$PRODUCT" ]; then
  echo "构建完成但没有找到：$PRODUCT" >&2
  find "$DERIVED/Build/Products" -maxdepth 3 -name '*.saver' -print >&2 || true
  exit 3
fi

mkdir -p "$DEST"
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x WallpaperLegacyExtension 2>/dev/null || true
pkill -x WallpaperAgent 2>/dev/null || true

# System Settings may rename an in-use replacement to “_副本” and keep the
# previous bundle loaded from Trash. Unregister and remove every duplicate of
# this saver before installing one canonical, signed bundle.
find "$DEST" -maxdepth 1 -type d -name 'Snoopy TV*.saver' \
  -exec /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u {} \; 2>/dev/null || true
find "$DEST" -maxdepth 1 -type d -name 'Snoopy TV*.saver' -exec rm -rf {} +
ditto "$PRODUCT" "$DEST/Snoopy TV.saver"
touch "$DEST/Snoopy TV.saver"
# A development identity can verify structurally yet be rejected by AMFI when
# legacyScreenSaver loads the copied bundle (for example while its certificate
# trust state is unavailable). This is a local plug-in, so seal the final copy
# ad-hoc after every resource mutation and verify exactly what will be loaded.
codesign --force --deep --sign - "$DEST/Snoopy TV.saver"
codesign --verify --deep --strict "$DEST/Snoopy TV.saver"
test -f "$DEST/Snoopy TV.saver/Contents/Resources/Assets.car"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST/Snoopy TV.saver" 2>/dev/null || true

# The extension is launchd-managed and can restart while the large resource
# bundle is still being copied. Restart it once more only after the final
# bundle is complete, sealed and registered, otherwise it caches a partial
# executable as "arch mismatch" until the next host lifecycle.
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x WallpaperLegacyExtension 2>/dev/null || true
pkill -x WallpaperAgent 2>/dev/null || true

# macOS 26 caches legacy saver thumbnails by module. This key is stable for
# com.dingdangnao.screensaver.snoopy; deleting only this file preserves every
# other legacy saver thumbnail and forces the supplied cover to be re-read.
CACHE_ROOT="$(dirname "${TMPDIR%/}")/C/com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails"
rm -f "$CACHE_ROOT/60267a63a5c4ec8b424ed1dd8f6742bd0c348613e92822888e50ca3d001980fb.png"

echo "已安装：$DEST/Snoopy TV.saver"
