// swift-tools-version:5.9
import PackageDescription

// One package, three parts:
//
//   TermsieCore     Foundation and SwiftTerm only: the model, workspaces and sessions, config,
//                   shell integration, command marks, text capture. Builds everywhere.
//   Termsie (mac)   The AppKit app, Sources/Termsie.
//   Termsie (win)   The Win32 app, Sources/TermsieWindows, with a small C++ target for Direct2D,
//                   DirectWrite and the Win32 APIs that are awkward to reach from Swift.
//
// Both apps are the executable target "Termsie", so `swift build` produces Termsie on macOS and
// Termsie.exe on Windows, and the existing Makefile and release scripts keep working. A manifest
// is evaluated on the host, which is also the target for every build these apps support.

let swiftTerm: Target.Dependency = .product(name: "SwiftTerm", package: "SwiftTerm")

var targets: [Target] = [
    .target(
        name: "TermsieCore",
        dependencies: [swiftTerm],
        path: "Sources/TermsieCore"
    ),
    .testTarget(
        name: "TermsieCoreTests",
        dependencies: ["TermsieCore", swiftTerm],
        path: "Tests/TermsieCoreTests"
    ),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "Termsie",
        dependencies: ["TermsieCore", swiftTerm],
        path: "Sources/Termsie",
        swiftSettings: [
            .unsafeFlags(["-Onone"], .when(configuration: .debug)),
        ]
    )
)
#elseif os(Windows)
targets += [
    .target(
        name: "CTermsieWin",
        path: "Sources/CTermsieWin",
        cxxSettings: [
            .define("UNICODE"),
            .define("_UNICODE"),
            .define("WIN32_LEAN_AND_MEAN"),
            .define("NOMINMAX"),
        ],
        linkerSettings: [
            .linkedLibrary("d2d1"),
            .linkedLibrary("dwrite"),
            .linkedLibrary("d3d11"),
            .linkedLibrary("dxgi"),
            .linkedLibrary("dcomp"),
            .linkedLibrary("windowscodecs"),
            .linkedLibrary("user32"),
            .linkedLibrary("gdi32"),
            .linkedLibrary("shell32"),
            .linkedLibrary("ole32"),
            .linkedLibrary("comdlg32"),
            .linkedLibrary("comctl32"),
            .linkedLibrary("advapi32"),
            .linkedLibrary("crypt32"),
            .linkedLibrary("wintrust"),
            .linkedLibrary("bcrypt"),
            .linkedLibrary("dwmapi"),
            .linkedLibrary("uxtheme"),
            .linkedLibrary("imm32"),
            .linkedLibrary("winmm"),
            .linkedLibrary("shlwapi"),
        ]
    ),
    .executableTarget(
        name: "Termsie",
        dependencies: ["TermsieCore", "CTermsieWin", swiftTerm],
        path: "Sources/TermsieWindows",
        linkerSettings: [
            // A GUI app: no console window of its own. Swift supplies `main`, so the C runtime's
            // console entry point is kept.
            .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
        ]
    ),
]
#endif

let package = Package(
    name: "Termsie",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.20.0")),
    ],
    targets: targets
)
