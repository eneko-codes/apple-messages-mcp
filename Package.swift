// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apple-messages-mcp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        // All logic lives here so the tests can import it. The executable target below
        // is only a launcher: an executable target cannot be imported by a test target.
        //
        // SQLite is `import SQLite3` from the macOS SDK — the system library the Messages
        // store is written with. No package dependency: a wrapper would add a few thousand
        // lines to audit in exchange for syntax.
        .target(
            name: "MessagesMCPCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "apple-messages-mcp",
            dependencies: ["MessagesMCPCore"],
            // TCC identifies this binary by its own embedded Info.plist. Claude Desktop
            // spawns MCP servers through Contents/Helpers/disclaimer, which calls
            // responsibility_spawnattrs_setdisclaim, so the process is its own TCC
            // subject and cannot borrow the host app's usage descriptions. Without the
            // embedded plist macOS denies the Apple event the send path needs without
            // ever prompting.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "MessagesMCPCoreTests", dependencies: ["MessagesMCPCore"]),
    ]
)
