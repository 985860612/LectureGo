// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CourseRec",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/HaishinKit/HaishinKit.swift.git",
            from: "2.2.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "CourseRec",
            dependencies: [
                .product(name: "HaishinKit", package: "HaishinKit.swift"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift")
            ],
            path: "Sources/CourseRec"
        )
    ]
)
