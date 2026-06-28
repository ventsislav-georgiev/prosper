// swift-tools-version: 6.0
import PackageDescription

// Prosper (v2) macOS app.
//
// Inference runs in-process via Apple's MLX (mlx-swift + mlx-swift-lm).
// See docs/ADR-001-mlx-engine.md. The Rust core (core/) is retired for
// inference and kept only as dormant legacy.
//
// NOTE: model architectures live in `ml-explore/mlx-swift-lm` (the LLM/VLM
// model code was extracted out of `mlx-swift-examples`). mlx-swift-lm ships the
// `gemma4` / `gemma4_text` architectures and registers the Gemma 4 E2B/E4B
// checkpoints in `LLMRegistry` (`mlx-community/gemma-4-e2b-it-4bit`,
// `...-e4b-it-4bit`) — the text-only path MLXEngine uses. mlx-swift-examples
// (the old dep) has no gemma4 arch, so it cannot run the required Gemma 4.
let package = Package(
    name: "Prosper",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // MLX LLM stack. MLXLLM/MLXLMCommon provide LLMModelFactory, ModelContainer,
        // GenerateParameters and the text-generation API used by MLXEngine.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            from: "3.31.3"
        ),
        // HuggingFace Hub client + Tokenizers backing the #hubDownloader() /
        // #huggingFaceTokenizerLoader() macros MLXEngine uses to fetch + load the
        // model. mlx-swift-lm intentionally has no Hub dependency of its own.
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            .upToNextMajor(from: "1.3.0")
        ),
        // Local encrypted-capable SQLite store (GRDB) backing typing-history
        // personalization + privacy data management. Data stays on-device.
        .package(
            url: "https://github.com/groue/GRDB.swift",
            from: "7.0.0"
        ),
        // In-app auto-update (appcast + EdDSA-signed releases). Requires a
        // hosted appcast feed + code-signing/notarization to function at runtime;
        // see README "Auto-update" + scripts/Info.plist SUFeedURL/SUPublicEDKey.
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.6.0"
        ),
        // Pure-Swift, Codable-driven TOML parser for extension.toml manifests.
        // Lightweight, no transitive deps. See docs/ADR-002-extensibility.md.
        .package(
            url: "https://github.com/dduan/TOMLDecoder",
            from: "0.4.0"
        ),
        // NOTE: opt-out usage analytics POST directly to the Aptabase EU endpoint via
        // URLSession (Analytics/AnalyticsService.swift) — no SDK dependency. The SDK
        // stamped "sent" on enqueue with no cross-launch persistence, so an offline
        // send was silently dropped; the self-POST stamps only on confirmed delivery.
    ],
    targets: [
        // Vendored Lua 5.4.7 interpreter (pure C99) backing the extension runtime.
        // See docs/ADR-002-extensibility.md. Pure bytecode VM — no JIT, no
        // MAP_JIT, so Hardened Runtime/notarization need no extra entitlements.
        // lua.c / luac.c (the standalone interpreter + compiler `main`s) are
        // intentionally NOT vendored — only the library translation units.
        .target(
            name: "CLua",
            cSettings: [
                .define("LUA_USE_MACOSX"),       // enables dlopen + readline-free posix bits for macOS
            ]
        ),
        // Swift wrapper around CLua: state lifecycle, sandbox (nil dangerous
        // globals), instruction-count budget hook, host-function registration.
        .target(
            name: "LuaRuntime",
            dependencies: ["CLua"]
        ),
        // The actual app.
        .executableTarget(
            name: "ProsperApp",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
                "LuaRuntime",
                "ProsperHelperProtocol",
                "StatsCore",
                "SMCKit",
            ],
            // NOTE: no `resources:` here on purpose. SwiftPM's generated
            // `Bundle.module` accessor resolves resources at
            // `Bundle.main.bundleURL/<Pkg_Target>.bundle`; for a packaged .app
            // that path is the .app ROOT, and placing a resource bundle at the
            // .app root breaks the code-signature seal (Sparkle's appcast
            // signing check then rejects the app: errSecCSResourcesNotSealed).
            // Instead scripts/bundle.sh copies Resources/extensions straight
            // into Contents/Resources, and ExtensionRegistry loads it via
            // Bundle.main (the standard, seal-clean macOS resource location).
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),        // RegisterEventHotKey for the global hotkey
                .linkedFramework("ApplicationServices"), // Accessibility (AXUIElement)
                .linkedFramework("CoreGraphics"),  // CGEventTap + screen capture (vision context)
                .linkedFramework("CoreImage"),     // CIImage for the VLM vision path
                .linkedFramework("ScreenCaptureKit"), // modern screen capture for vision context
                .linkedFramework("ServiceManagement"), // SMAppService (launch at login)
                .linkedFramework("UserNotifications"), // extension host.notify API
            ]
        ),
        // Shared XPC contract (protocol + identifiers) between ProsperApp and the
        // privileged lid-sleep daemon. Tiny, no deps — its own target so both
        // executables compile the exact same interface.
        .target(
            name: "ProsperHelperProtocol"
        ),
        // Privileged helper daemon behind "keep awake with the lid closed". Runs
        // as root via launchd (installed by SMAppService.daemon), flips
        // `pmset -a disablesleep` over XPC. Removes the old NOPASSWD sudoers hack.
        // Embedded into the .app by scripts/bundle.sh; see that script + the
        // LaunchDaemons plist it writes.
        .executableTarget(
            name: "ProsperHelper",
            dependencies: ["ProsperHelperProtocol", "SMCKit"],
            // RemoteWakeSPI.h re-declares the IOPMConnection dark-wake observer
            // family (SPI, exported from IOKit but absent from the SDK headers).
            // No entitlement; passes notarization. See the header for why.
            swiftSettings: [
                .unsafeFlags(["-import-objc-header", "Sources/ProsperHelper/include/RemoteWakeSPI.h"])
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        // Dummy GUI app driven by the e2e suites. A real external process so it
        // can be the frontmost app (xctest can't on macOS 14+); shows one
        // input-field kind from argv[1], focuses it, and logs a value transcript.
        // Reused across e2e suites (snippets, inline autocomplete, …). See main.swift.
        .executableTarget(
            name: "E2EHost",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
            ]
        ),
        // System Management Controller read/write over IOKit (public API only).
        // Read side (fans/temps/power) used by ProsperApp; guarded write side
        // (fan control, root-only) used by ProsperHelper. No private symbols,
        // no AppKit/MLX — compiles fast, testable in isolation.
        .target(
            name: "SMCKit",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        // System-monitor core: readers (CPU/RAM/Net/GPU/Sensors/Battery), ring
        // buffers, tiered poller. AppKit-free so the hot paths are unit-testable
        // without the heavy ProsperApp (MLX/Metal/AppKit) build. UI lives in
        // ProsperApp; this is the pure data layer. See .omc/plans/system-stats-modules.md.
        .target(
            name: "StatsCore",
            dependencies: ["SMCKit"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Unit tests for the deterministic command-runner engines (calc, units).
        // LLM + network + GUI paths are not covered here (require model/Metal).
        .testTarget(
            name: "ProsperAppTests",
            dependencies: ["ProsperApp", "LuaRuntime"]
        ),
        // Fast-iterating unit tests for the AppKit-free system-monitor core:
        // ring buffers, decoders, reader correctness, hot-path budgets.
        .testTarget(
            name: "StatsCoreTests",
            dependencies: ["StatsCore", "SMCKit"]
        ),
    ]
)
