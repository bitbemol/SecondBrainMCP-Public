// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SecondBrainMCP",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "second-brain-mcp", targets: ["SecondBrainMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0")
    ],
    targets: [
        .executableTarget(
            name: "SecondBrainMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "SecondBrainMCPTests",
            dependencies: ["SecondBrainMCP"]
        )
    ]
)
// Note: PDFKit is a system framework — no dependency entry needed.
// Just `import PDFKit` in the source files that use it.
