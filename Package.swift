// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            path: "Sources/MeetingRecorder",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
