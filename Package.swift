// swift-tools-version:5.9
import PackageDescription

// One package, three parts:
//
//   TermsieCore     Foundation and SwiftTerm only: the model, workspaces and sessions, config,
//                   shell integration, command marks, text capture. Builds everywhere.
//   Termsie (mac)   The AppKit app, Sources/Termsie.
//   Termsie (app)   The raster front end shared by Windows and Linux, Sources/TermsieApp: one
//                   window drawn in a single pass over a flat C contract (CTermsieHost.h). The
//                   platform underneath lives in Sources/TermsieApp/Host/<platform> and in
//                   Sources/CTermsieHost/<platform>: Win32 with Direct2D and DirectWrite on
//                   Windows, GTK 4 with Cairo and Pango on Linux.
//
// Every app is the executable target "Termsie", so `swift build` produces Termsie on macOS and
// Linux, and Termsie.exe on Windows, and the existing Makefile and release scripts keep working.
// A manifest is evaluated on the host, which is also the target for every build these apps
// support.

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
        name: "CTermsieHost",
        path: "Sources/CTermsieHost",
        exclude: ["linux"],
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
        dependencies: ["TermsieCore", "CTermsieHost", swiftTerm],
        path: "Sources/TermsieApp",
        exclude: ["Host/Linux"],
        linkerSettings: [
            // A GUI app: no console window of its own. Swift supplies `main`, so the C runtime's
            // console entry point is kept.
            .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
        ]
    ),
]
#elseif os(Linux)
targets += [
    // GTK 4 and libsecret come from the system through pkg-config: `libgtk-4-dev` and
    // `libsecret-1-dev` on Debian and Ubuntu.
    .systemLibrary(name: "CGtk4", path: "Sources/CGtk4", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
    .systemLibrary(name: "CLibSecret", path: "Sources/CLibSecret", pkgConfig: "libsecret-1",
                   providers: [.apt(["libsecret-1-dev"])]),
    .target(
        name: "CTermsieHost",
        dependencies: ["CGtk4", "CLibSecret"],
        path: "Sources/CTermsieHost",
        exclude: ["windows"]
    ),
    .executableTarget(
        name: "Termsie",
        dependencies: ["TermsieCore", "CTermsieHost", swiftTerm],
        path: "Sources/TermsieApp",
        exclude: ["Host/Win32"]
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
