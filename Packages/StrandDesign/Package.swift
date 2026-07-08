// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandDesign",
    // The package carries its OWN string catalog (Sources/StrandDesign/Resources/Localizable.xcstrings).
    // defaultLocalization is what makes SPM build the localized resource bundle at all; every
    // String(localized:) in the package passes `bundle: .module` so lookups hit that catalog instead of
    // silently falling back to the host app's main bundle (where package-only keys do not exist).
    defaultLocalization: "en",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [.library(name: "StrandDesign", targets: ["StrandDesign"])],
    dependencies: [],
    targets: [
        .target(name: "StrandDesign", resources: [.process("Resources")]),
        .testTarget(name: "StrandDesignTests", dependencies: ["StrandDesign"]),
    ]
)
