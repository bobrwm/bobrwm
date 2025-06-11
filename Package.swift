// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "bobrwm",
	platforms: [.macOS(.v13)],
	targets: [
		.target(
			name: "Private",
			publicHeadersPath: "Include"
		),
		.executableTarget(
			name: "BobrWMApp",
			dependencies: [
				.target(name: "Private")
			]
		),
	]
)
