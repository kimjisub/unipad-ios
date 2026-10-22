// swift-tools-version: 5.9
import PackageDescription

// The Xiph.Org Ogg Vorbis decoder, built from the release sources and upstream fixes that
// vendor.sh copies into Sources/. AVFoundation cannot open Ogg Vorbis, which the UniPack format
// recommends for sounds. The one warning the sources raise throughout (64-to-32-bit conversions
// the reference code makes on purpose) is turned off rather than patched.
let upstreamWarnings: [CSetting] = [.unsafeFlags(["-Wno-shorten-64-to-32"])]

let package = Package(
    name: "XiphVorbis",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CVorbis", targets: ["CVorbis"]),
    ],
    targets: [
        .target(name: "COgg", cSettings: upstreamWarnings),
        .target(name: "CVorbis", dependencies: ["COgg"], cSettings: upstreamWarnings),
    ]
)
