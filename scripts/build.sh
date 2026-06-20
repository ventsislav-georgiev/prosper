#!/usr/bin/env bash
# Build the Swift app. (Inference runs in Swift via Apple MLX; the former Rust
# core was retired — see docs/ADR-001-mlx-engine.md.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PROFILE="${1:-release}"

echo "==> Building Swift app ($PROFILE)"
# Re-apply local dependency patches (e.g. mlx-swift-lm QAT 4-bit support) against
# the SwiftPM checkouts before compiling. Idempotent — safe on warm caches.
"$ROOT/scripts/apply-patches.sh"
cd "$ROOT/app"
if [[ "$PROFILE" == "release" ]]; then
  swift build -c release
else
  swift build
fi
# --- MLX Metal shaders (default.metallib) --------------------------------
# Apple MLX runs its kernels from a precompiled `default.metallib` shipped in a
# `mlx-swift_Cmlx.bundle` resource bundle (the C++ define SWIFTPM_BUNDLE +
# METAL_PATH in mlx-swift's Package.swift). Plain `swift build` CANNOT compile
# Metal shaders — only `xcodebuild` can (mlx-swift README explicitly says so).
# Without the metallib the app aborts the instant it touches the GPU:
#   "MLX error: Failed to load the default metallib. library not found ...
#    mlx-swift/.../mlx/c/stream.cpp" — i.e. crash on first model load.
# So after the SwiftPM build we drive a one-shot `xcodebuild` of the Prosper
# scheme purely to produce that bundle, then stage it into .build/$PROFILE/ so
# scripts/bundle.sh's existing *.bundle copy loop ships it into the .app.
# The metallib is AIR (arch-portable, config-independent), so a Release build of
# it serves every PROFILE.
METALLIB_BUNDLE="$ROOT/app/.build/$PROFILE/mlx-swift_Cmlx.bundle"
if [[ -f "$METALLIB_BUNDLE/Contents/Resources/default.metallib" ]]; then
  echo "==> MLX metallib already staged: $METALLIB_BUNDLE"
else
  echo "==> Compiling MLX Metal shaders via xcodebuild (swift build cannot)"
  if ! /usr/bin/xcrun -f metal >/dev/null 2>&1; then
    echo "==> Metal toolchain missing — downloading (one-time, ~700 MB)"
    xcodebuild -downloadComponent MetalToolchain
  fi
  DD="$ROOT/app/.build/xcode-metallib"
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
  echo "==> Staged MLX metallib: $METALLIB_BUNDLE"
fi

# Keep my personal example extensions installed + current in ~/.config/prosper
# (version-gated, skips if unchanged). Self-skips in CI; never fails the build.
"$ROOT/scripts/install-example-extensions.sh" || true

echo "==> Done. Binary: $ROOT/app/.build/$PROFILE/ProsperApp"
echo "    Package as .app with: scripts/bundle.sh $PROFILE"
