#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

configuration=${1:-debug}
if [[ $# -gt 0 ]]; then shift; fi
case "$configuration" in
    debug|release) ;;
    *) echo "Usage: bash scripts/package-macos.sh [debug|release] [--dmg] [Swift build options]" >&2; exit 2 ;;
esac

make_dmg=false
if [[ ${1:-} == --dmg ]]; then
    make_dmg=true
    shift
fi

version=$(plutil -extract version raw -o - tauri/src-tauri/tauri.conf.json)
if [[ ${GITHUB_REF_TYPE:-} == tag && ${GITHUB_REF_NAME:-} != "v$version" ]]; then
    echo "Tag ${GITHUB_REF_NAME:-} does not match version $version" >&2
    exit 1
fi

bash scripts/generate-localizable.sh
swift build -c "$configuration" "$@"
bin_dir=$(swift build -c "$configuration" "$@" --show-bin-path)
executable="$bin_dir/BrushLLMPlayer"
architecture=$(lipo -archs "$executable")
if [[ "$make_dmg" == true && "$architecture" != arm64 ]]; then
    echo "The macOS release disk image requires an arm64 executable" >&2
    exit 1
fi

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
app_name="BrushLLM Player.app"
app="$staging/$app_name"
contents="$app/Contents"
resources="$contents/Resources"
mkdir -p "$contents/MacOS" "$resources"
cp "$executable" "$contents/MacOS/BrushLLMPlayer"
cp LICENSE "$resources/"
cp -R Sources/BrushLLMPlayer/Resources/*.lproj "$resources/"
cp scripts/Info.plist "$contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$contents/Info.plist"

iconset="$staging/Player.iconset"
icon_source="$resources/Base.lproj/PlayerIcon.svg"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$icon_source" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -s format png -z "$retina" "$retina" "$icon_source" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$resources/AppIcon.icns" "$iconset"

codesign --force --sign - "$app"
codesign --verify --strict "$app"
mkdir -p build
if [[ "$make_dmg" == true ]]; then
    disk_root="$staging/disk"
    mkdir "$disk_root"
    cp -R "$app" "$disk_root/"
    ln -s /Applications "$disk_root/Applications"
    dmg="BrushLLM.Player-$version-arm64.dmg"
    hdiutil create -volname "BrushLLM Player" -srcfolder "$disk_root" -format UDZO "$staging/$dmg"
    mv -f "$staging/$dmg" "build/$dmg"
fi
rm -rf "build/$app_name"
mv "$app" "build/$app_name"
echo "Assembled build/$app_name"
