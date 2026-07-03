#!/usr/bin/env bash
# Apply local patches to SwiftPM dependency checkouts.
#
# We pin mlx-swift-lm via SwiftPM (see app/Package.swift / Package.resolved) but
# carry a small fix on top of the upstream tag: Gemma 3n (gemma-4) QAT 4-bit
# checkpoints use heterogeneous per-layer quantization AND omit K/V projections
# + K/V norms on KV-shared layers. Stock mlx-swift-lm 3.31.3 can't load them
# (mismatchedSize on the quantized per-layer projection; keyNotFound on
# k_proj/k_norm/v_norm for shared layers). The patch makes ScaledLinear
# quantizable and gates K/V proj+norm allocation on non-shared layers.
#
# Rather than fork, we keep the upstream pin and re-apply this patch against the
# fresh checkout on every build (local + CI). Idempotent: a `--reverse --check`
# probe detects an already-applied patch and skips it, so repeated runs and
# warm SwiftPM caches are safe.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$ROOT/app/patches"

# "<patch-file>:<checkout-dir>" pairs. NOTE: plain array, not `declare -A` —
# macOS CI runners only have bash 3.2 (/bin/bash), which lacks associative
# arrays (`declare: -A: invalid option` kills the build instantly).
PATCHES=(
  "mlx-swift-lm-qat.patch:mlx-swift-lm"
  "llama4-arch.patch:mlx-swift-lm"
  # Expose a task-returning generateTask overload for SpeculativeTokenIterator
  # (upstream only returns the bare stream, discarding the producer Task). We
  # need that Task to cancel+join after breaking out of the stream — otherwise
  # the producer keeps stepping the model/KV cache while we trim or persist it
  # (range-inversion crash in KVCacheSimple.update) and keeps computing outside
  # MLXComputeGate.
  "mlx-swift-lm-speculative-task.patch:mlx-swift-lm"
)

cd "$ROOT/app"

# Checkouts only exist after dependency resolution; populate them if missing so
# the patch has something to apply to before `swift build` compiles them.
if [[ ! -d .build/checkouts ]]; then
  echo "==> Resolving SwiftPM dependencies (no checkouts yet)"
  swift package resolve
fi

# Two checkout roots: swift build's, and xcodebuild's separate SourcePackages
# (the metallib step in build.sh compiles the WHOLE app from that second tree —
# unpatched, mlx-swift-lm fails with 'SpeculativeTokenIterator' type errors).
# The xcode tree only exists after its first resolve; optional until then —
# build.sh re-runs this script right before xcodebuild.
CHECKOUT_ROOTS=(".build/checkouts")
XCODE_CHECKOUTS=".build/xcode-metallib/SourcePackages/checkouts"
if [[ -d "$XCODE_CHECKOUTS" ]]; then
  CHECKOUT_ROOTS+=("$XCODE_CHECKOUTS")
fi

for entry in "${PATCHES[@]}"; do
  patch="${entry%%:*}"
  patch_path="$PATCH_DIR/$patch"
  if [[ ! -f "$patch_path" ]]; then
    echo "error: patch not found: $patch_path" >&2
    exit 1
  fi
  for root in "${CHECKOUT_ROOTS[@]}"; do
    checkout="$root/${entry##*:}"
    if [[ ! -d "$checkout" ]]; then
      if [[ "$root" == ".build/checkouts" ]]; then
        echo "error: checkout not found: $checkout (dependency resolution failed?)" >&2
        exit 1
      fi
      continue  # xcode tree may not have resolved this dep yet
    fi
    if git -C "$checkout" apply --reverse --check "$patch_path" >/dev/null 2>&1; then
      echo "==> $patch already applied to $checkout — skipping"
      continue
    fi
    if ! git -C "$checkout" apply --check "$patch_path" >/dev/null 2>&1; then
      echo "error: $patch does not apply cleanly to $checkout" >&2
      echo "       (upstream pin may have changed; regenerate the patch)" >&2
      exit 1
    fi
    git -C "$checkout" apply "$patch_path"
    echo "==> Applied $patch to $checkout"
  done
done
