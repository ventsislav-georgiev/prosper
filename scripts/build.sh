#!/usr/bin/env bash
# Build the Swift app. (Inference runs in Swift via Apple MLX; the former Rust
# core was retired — see docs/ADR-001-mlx-engine.md.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PROFILE="${1:-release}"

echo "==> Building Swift app ($PROFILE)"
cd "$ROOT/app"
# The linked SDK version (LC_BUILD_VERSION sdk, checked below) reaches the
# linker only through SDKROOT: swift-driver passes --sysroot, which clang does
# not read for it. /usr/bin/swift (the xcrun shim) sets SDKROOT, the toolchain
# binary path does not, so pin it here whoever calls us (QA #226).
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
# --build-system native, not the swiftbuild default since Xcode 27: swiftbuild
# runs its link task without SDKROOT, so its products say sdk 14.0 and AppKit
# runs them with macOS 14 behaviour on 26 and 27 (QA #226 on #416). Native
# inherits the export above. ponytail: back to the default backend once a
# vtool check on its product reads the host SDK; the flag is deprecated.
if [[ "$PROFILE" == "release" ]]; then
  swift build --build-system native -c release
else
  swift build --build-system native
fi

# The linker records the SDK it linked against (LC_BUILD_VERSION sdk) and AppKit
# keys compatibility behaviour off it: a binary that says 14.0 runs with macOS 14
# quirks on 26 and 27, and the macOS 27 session paths compile in but behave old.
# clang takes that version from -isysroot or SDKROOT only, never from the
# --sysroot swift-driver's link job passes, so SDKROOT must reach the link (see
# the export above). Gate it here so no backend or shell can ship a 14.0 (QA #226).
for bin in ProsperApp ProsperHelper; do
  got="$(xcrun vtool -show-build ".build/$PROFILE/$bin" | awk '/^ *sdk /{print $2}')"
  [[ "${got%%.*}" -ge 26 ]] || { echo "error: $bin linked against SDK ${got:-?} (expected >= 26)" >&2; exit 1; }
  echo "==> $bin links against SDK $got"
done

# --- MLX Metal shaders (default.metallib) --------------------------------
# Apple MLX runs its kernels from a precompiled `default.metallib` shipped in a
# `mlx-swift_Cmlx.bundle` resource bundle (the C++ define SWIFTPM_BUNDLE +
# METAL_PATH in mlx-swift's Package.swift). The native SwiftPM backend cannot
# compile Metal shaders, so a Release build of the ProsperApp scheme via
# xcodebuild produces the metallib and it is staged into the SwiftPM bundle
# below. (The swiftbuild backend compiles it in-tree, byte-identical, but links
# against the wrong SDK, see above; #422 drops this step once that is fixed.)
# Without the metallib the app aborts the instant it touches the GPU:
#   "MLX error: Failed to load the default metallib. library not found ...
#    mlx-swift/.../mlx/c/stream.cpp" — i.e. crash on first model load.
# So after the SwiftPM build we drive a one-shot `xcodebuild` of the Prosper
# scheme purely to produce that bundle, then stage it into .build/$PROFILE/ so
# scripts/bundle.sh's existing *.bundle copy loop ships it into the .app.
# The metallib is AIR (arch-portable, config-independent), so a Release build of
# it serves every PROFILE.
METALLIB_BUNDLE="$ROOT/app/.build/$PROFILE/mlx-swift_Cmlx.bundle"
# The metallib is MLX's compiled shaders, so it's only valid for the MLX version
# the build resolved. Stamp the staged bundle with Package.resolved's hash and
# rebuild when it changes — otherwise a metallib restored from a stale SwiftPM
# cache (CI restore-keys can fall back to an older cache after a dep bump) would
# be skipped here and shipped against the wrong MLX → crash on first model load.
RESOLVED_HASH=$(/usr/bin/shasum -a 256 "$ROOT/app/Package.resolved" | cut -d' ' -f1)
METALLIB_STAMP="$METALLIB_BUNDLE/.prosper-resolved-hash"
if [[ -f "$METALLIB_BUNDLE/Contents/Resources/default.metallib" \
   && "$(cat "$METALLIB_STAMP" 2>/dev/null)" == "$RESOLVED_HASH" ]]; then
  echo "==> MLX metallib already staged (matches Package.resolved): $METALLIB_BUNDLE"
else
  echo "==> Compiling MLX Metal shaders via xcodebuild"
  # Only this step needs the Metal toolchain (the native backend compiles no
  # Metal), and CI images ship without it: a cache-staged metallib skips the
  # ~840 MB download (QA on run 38392780742). xcrun -f finds a stub that exists
  # before the component is downloaded (cache-warm run 38386428435), so run it.
  if ! /usr/bin/xcrun metal --version >/dev/null 2>&1; then
    echo "==> Metal toolchain missing — downloading (one-time, ~840 MB)"
    xcodebuild -downloadComponent MetalToolchain
  fi
  DD="$ROOT/app/.build/xcode-metallib"
  # We only get here when the staged metallib is missing or carries another
  # Package.resolved hash (fresh checkout, cleaned .build/<profile>, dependency
  # bump). A restored CI cache then still holds this DerivedData's intermediates (explicit
  # module .pcm files, objects) built against the previous dependency set, and
  # xcodebuild refuses them: "SUAppcastItem.h has been modified since the module
  # file ... was built" (Sparkle 2.9.3 → 2.10.0 failed the v2.156.0-beta.1 run).
  # Start the build tree clean; the resolved checkouts in SourcePackages stay.
  rm -rf "$DD/Build"
  # xcodebuild compiles from its OWN SourcePackages tree — resolve it first.
  xcodebuild -resolvePackageDependencies \
    -scheme ProsperApp \
    -destination 'platform=macOS' \
    -derivedDataPath "$DD"
  xcodebuild build \
    -scheme ProsperApp \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DD" \
    -skipMacroValidation \
    -skipPackagePluginValidation
  SRC=$(/usr/bin/find "$DD/Build/Products" -name 'mlx-swift_Cmlx.bundle' -type d 2>/dev/null | /usr/bin/head -n1)
  if [[ -z "$SRC" || ! -f "$SRC/Contents/Resources/default.metallib" ]]; then
    echo "error: xcodebuild did not produce mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" >&2
    exit 1
  fi
  rm -rf "$METALLIB_BUNDLE"
  cp -R "$SRC" "$METALLIB_BUNDLE"
  printf '%s' "$RESOLVED_HASH" > "$METALLIB_STAMP"
  echo "==> Staged MLX metallib: $METALLIB_BUNDLE"
fi

# Keep my personal example extensions installed + current in ~/.config/prosper
# (version-gated, skips if unchanged). Self-skips in CI; never fails the build.
"$ROOT/scripts/install-example-extensions.sh" || true

echo "==> Done. Binary: $ROOT/app/.build/$PROFILE/ProsperApp"
echo "    Package as .app with: scripts/bundle.sh $PROFILE"
