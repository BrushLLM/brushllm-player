#!/bin/bash
# BrushLLM Player toolchain shim setup
#
# Why this exists:
#   This machine's Command Line Tools installation is internally inconsistent:
#   /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/ contains a
#   CURRENT libPackageDescription.dylib and public .swiftinterface (Swift 6.3.3),
#   but a STALE .private.swiftinterface from early 2024. When both are present the
#   Swift compiler resolves the manifest's Package() initializer against the stale
#   private interface, emitting a symbol the current dylib does not export, so
#   every `swift build` fails at manifest link time with:
#     "Undefined symbols ... Package.__allocating_init(... swiftLanguageVersions ...)"
#
#   The fix is to give SwiftPM a ManifestAPI directory without the stale private
#   interfaces. The system directory is root-owned, so instead we build a "shim
#   toolchain" in the user's home and put it first on PATH. SwiftPM derives the
#   toolchain root from the location of the swift driver binary, so the shim must
#   contain a real COPY of the swift binary (a symlink would be resolved back to
#   the system toolchain).
#
#   The proper system-level fix (needs sudo, optional):
#     sudo rm /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface
#     sudo rm /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/CompilerPluginSupport.swiftmodule/*.private.swiftinterface
#   (or reinstall Command Line Tools). After that this shim is unnecessary.

set -euo pipefail

CLT=/Library/Developer/CommandLineTools
SHIM="$HOME/toolchains/brushplayer-spmfix"

if [ ! -d "$CLT" ]; then
    echo "error: Command Line Tools not found at $CLT" >&2
    exit 1
fi

mkdir -p "$SHIM/usr/bin" "$SHIM/usr/lib/swift/pm"

# All tools are symlinked; only `swift` must be a real copy so SwiftPM treats the
# shim directory as the toolchain root.
for f in "$CLT/usr/bin/"*; do
    name=$(basename "$f")
    if [ "$name" = "swift" ]; then
        rm -f "$SHIM/usr/bin/swift"
        cp "$f" "$SHIM/usr/bin/swift"
    else
        ln -sf "$f" "$SHIM/usr/bin/$name"
    fi
done

# Mirror usr/lib, but keep swift/pm/ManifestAPI as a real (fixed) copy.
for item in "$CLT/usr/lib/"*; do
    name=$(basename "$item")
    [ "$name" = "swift" ] && continue
    ln -sfn "$item" "$SHIM/usr/lib/$name"
done
for item in "$CLT/usr/lib/swift/"*; do
    name=$(basename "$item")
    [ "$name" = "pm" ] && continue
    ln -sfn "$item" "$SHIM/usr/lib/swift/$name"
done
for item in "$CLT/usr/lib/swift/pm/"*; do
    name=$(basename "$item")
    [ "$name" = "ManifestAPI" ] && continue
    ln -sfn "$item" "$SHIM/usr/lib/swift/pm/$name"
done

rm -rf "$SHIM/usr/lib/swift/pm/ManifestAPI"
cp -R "$CLT/usr/lib/swift/pm/ManifestAPI" "$SHIM/usr/lib/swift/pm/ManifestAPI"
rm -f "$SHIM/usr/lib/swift/pm/ManifestAPI/"*swiftmodule/*.private.swiftinterface

echo "Shim toolchain ready: $SHIM"
echo "Build with: PATH=\"$SHIM/usr/bin:\$PATH\" swift build"
