#!/bin/bash
# Builds BrushLLM Player and assembles the .app bundle.
#
# MPVKit's xcframeworks are static libraries, so the bundle is just the
# executable plus Info.plist — no frameworks to carry.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
SHIM="$HOME/toolchains/brushplayer-spmfix"

# Toolchain selection: when xcode-select points at a full Xcode (versioned
# names like Xcode_16.1.app included), build with it directly. The PATH shim
# (a copied CLT swift + fixed ManifestAPI) is only for the legacy state where
# xcode-select pointed at an internally inconsistent Command Line Tools
# install — and its copied compiler goes stale (version mismatch against new
# SDKs) whenever Xcode is updated, so it must not be used when a real Xcode
# toolchain is selected.
if xcode-select -p 2>/dev/null | grep -q "Xcode"; then
    echo "==> Using Xcode toolchain ($(xcode-select -p))"
    SWIFT_ENV=()
else
    if [ ! -x "$SHIM/usr/bin/swift" ]; then
        echo "==> Toolchain shim missing, creating it first"
        ./scripts/setup-toolchain.sh
    fi
    echo "==> Using shim toolchain $SHIM"
    SWIFT_ENV=("PATH=$SHIM/usr/bin:$PATH")
fi

echo "==> Regenerating embedded strings"
./scripts/generate-localizable.sh

echo "==> swift build -c $CONFIG"
if [ ${#SWIFT_ENV[@]} -gt 0 ]; then
    env "${SWIFT_ENV[@]}" swift build -c "$CONFIG"
else
    swift build -c "$CONFIG"
fi

BUILD_DIR=".build/$CONFIG"
APP="build/BrushLLM Player.app"
CONTENTS="$APP/Contents"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BUILD_DIR/BrushLLMPlayer" "$CONTENTS/MacOS/BrushLLMPlayer"
cp LICENSE "$CONTENTS/Resources/LICENSE"
cp Assets/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# Localization folders: the embedded string tables are compiled into the
# binary for instant in-app switching; the .lproj copies exist so the bundle
# declares its languages, which makes AppKit localize the standard menus
# (File/Edit/View/Window/Help) to the system language.
for lang_dir in Sources/BrushLLMPlayer/Resources/*.lproj; do
    cp -R "$lang_dir" "$CONTENTS/Resources/"
done

cat > "$CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>BrushLLM Player</string>
    <key>CFBundleDisplayName</key>
    <string>BrushLLM Player</string>
    <key>CFBundleIdentifier</key>
    <string>dev.brushllm.player</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.6</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>BrushLLMPlayer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>de</string>
        <string>es</string>
        <string>fr</string>
        <string>id</string>
        <string>it</string>
        <string>nl</string>
        <string>pl</string>
        <string>pt-BR</string>
        <string>tr</string>
        <string>vi</string>
        <string>ja</string>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
        <string>ko</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video file</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audiovisual-content</string>
                <string>public.movie</string>
                <string>public.video</string>
                <string>public.avi</string>
                <string>public.mpeg</string>
                <string>public.mpeg-4</string>
                <string>public.mpeg-4-movie</string>
                <string>com.apple.m4v-video</string>
                <string>com.apple.quicktime-movie</string>
                <string>org.matroska.mkv</string>
                <string>org.webmproject.webm</string>
                <string>public.mpeg-2-transport-stream</string>
                <string>dev.brushllm.video</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Audio file</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
                <string>public.mp3</string>
                <string>public.mpeg-4-audio</string>
                <string>com.apple.m4a-audio</string>
                <string>org.xiph.flac</string>
                <string>org.xiph.ogg-audio</string>
                <string>com.microsoft.waveform-audio</string>
                <string>public.aiff-audio</string>
                <string>dev.brushllm.audio</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Playlist</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>dev.brushllm.playlist</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Disc image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.iso-image</string>
                <string>dev.brushllm.disc</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>dev.brushllm.video</string>
            <key>UTTypeDescription</key>
            <string>Video file</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.movie</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>mkv</string>
                    <string>mp4</string>
                    <string>m4v</string>
                    <string>mov</string>
                    <string>avi</string>
                    <string>wmv</string>
                    <string>flv</string>
                    <string>f4v</string>
                    <string>ts</string>
                    <string>m2ts</string>
                    <string>mts</string>
                    <string>vob</string>
                    <string>3gp</string>
                    <string>ogv</string>
                    <string>rm</string>
                    <string>rmvb</string>
                    <string>asf</string>
                    <string>divx</string>
                    <string>mxf</string>
                    <string>m2v</string>
                    <string>mpg</string>
                    <string>mpeg</string>
                    <string>bik</string>
                    <string>ivf</string>
                    <string>y4m</string>
                    <string>webm</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>dev.brushllm.audio</string>
            <key>UTTypeDescription</key>
            <string>Audio file</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.audio</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>mp3</string>
                    <string>m4a</string>
                    <string>aac</string>
                    <string>flac</string>
                    <string>ogg</string>
                    <string>oga</string>
                    <string>opus</string>
                    <string>wav</string>
                    <string>aif</string>
                    <string>aiff</string>
                    <string>caf</string>
                    <string>wma</string>
                    <string>ape</string>
                    <string>ac3</string>
                    <string>dts</string>
                    <string>mka</string>
                    <string>amr</string>
                    <string>mpc</string>
                    <string>wv</string>
                    <string>spx</string>
                    <string>dsf</string>
                    <string>tta</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>dev.brushllm.playlist</string>
            <key>UTTypeDescription</key>
            <string>Playlist</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>m3u</string>
                    <string>m3u8</string>
                    <string>pls</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>dev.brushllm.disc</string>
            <key>UTTypeDescription</key>
            <string>Disc image</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>iso</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "==> Ad-hoc code signing"
codesign --force --sign - "$APP"

echo "==> Done: $APP"
