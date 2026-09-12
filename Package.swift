// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperTypeCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WhisperTypeCore", targets: ["WhisperTypeCore"])],
    targets: [
        .target(
            name: "WhisperTypeCore",
            path: "WhisperType",
            exclude: [
                "App", "UI", "Assets.xcassets", "AppDelegate.swift", "Info.plist", "WhisperType.entitlements",
                "main.swift", "Core/AppDataStore.swift", "Services/AIRefinementService.swift",
                "Services/AudioRecordingService.swift", "Services/ContextAndInsertionService.swift",
                "Services/HotkeyManager.swift", "Services/LaunchAtLoginService.swift",
                "Services/PermissionService.swift", "Services/SecureStore.swift", "Services/TranscriptionService.swift"
            ],
            sources: ["Core/Models.swift", "Services/TextProcessingService.swift"]
        ),
        .testTarget(name: "WhisperTypeCoreTests", dependencies: ["WhisperTypeCore"])
    ]
)
