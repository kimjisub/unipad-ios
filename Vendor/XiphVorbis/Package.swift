// swift-tools-version: 5.9
import PackageDescription

// The Xiph.Org Ogg Vorbis and Opus libraries, copied by vendor.sh and vendor_opus.py.
// They decode Ogg sounds on OS versions without native support. The reference code makes
// 64-to-32-bit conversions on purpose; that warning is turned off rather than patched.
let upstreamWarnings: [CSetting] = [.unsafeFlags(["-Wno-shorten-64-to-32"])]

let package = Package(
    name: "XiphVorbis",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CVorbis", targets: ["CVorbis"]),
        .library(name: "COpusFile", targets: ["COpusFile"]),
    ],
    targets: [
        .target(name: "COpus", cSettings: upstreamWarnings + [
            // Opus requires optimization even in Debug to avoid its slow decoder path.
            .unsafeFlags(["-O2"], .when(configuration: .debug)),
            .define("OPUS_BUILD"), .define("VAR_ARRAYS"),
            .define("HAVE_LRINT"), .define("HAVE_LRINTF"),
            .headerSearchPath("celt"), .headerSearchPath("silk"),
            .headerSearchPath("silk/float"), .headerSearchPath("src"),
        ]),
        .target(name: "COpusFile", dependencies: ["COpus", "COgg"], cSettings: upstreamWarnings),
        .target(name: "COgg", cSettings: upstreamWarnings),
        .target(name: "CVorbis", dependencies: ["COgg"], cSettings: upstreamWarnings),
    ]
)
