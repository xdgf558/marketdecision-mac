// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "MarketDecision",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MarketDecisionFoundation", targets: ["AppComposition"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "CoreDomain", dependencies: [], path: "Sources/CoreDomain"),
        .target(name: "CoreCalculations", dependencies: ["CoreDomain"], path: "Sources/CoreCalculations"),
        .target(name: "DataContracts", dependencies: ["CoreDomain"], path: "Sources/DataContracts"),
        .target(name: "DataProviders", dependencies: ["CoreDomain", "DataContracts"], path: "Sources/DataProviders"),
        .target(name: "SECProvider", dependencies: ["DataProviders"], path: "Sources/SECProvider"),
        .target(name: "MarketDataProviders", dependencies: ["DataProviders"], path: "Sources/MarketDataProviders"),
        .target(name: "MacroProviders", dependencies: ["DataProviders"], path: "Sources/MacroProviders"),
        .target(name: "FundamentalsEngine", dependencies: ["CoreCalculations", "DataContracts"], path: "Sources/FundamentalsEngine"),
        .target(name: "OptionsAnalytics", dependencies: ["CoreCalculations", "DataContracts"], path: "Sources/OptionsAnalytics"),
        .target(name: "BacktestEngine", dependencies: ["CoreCalculations", "DataContracts"], path: "Sources/BacktestEngine"),
        .target(name: "PortfolioEngine", dependencies: ["CoreCalculations", "DataContracts"], path: "Sources/PortfolioEngine"),
        .target(name: "DecisionJournal", dependencies: ["CoreDomain", "DataContracts"], path: "Sources/DecisionJournal"),
        .target(name: "AlertEngine", dependencies: ["CoreDomain", "DataContracts"], path: "Sources/AlertEngine"),
        .target(name: "Persistence", dependencies: ["CoreDomain", "DataContracts", .product(name: "GRDB", package: "GRDB.swift")], path: "Sources/Persistence"),
        .target(name: "SecuritySupport", dependencies: [], path: "Sources/Security"),
        .target(name: "AIInsights", dependencies: ["CoreDomain", "DataContracts"], path: "Sources/AIInsights"),
        .target(name: "UIComponents", dependencies: [], path: "Sources/UIComponents"),
        .target(name: "AppComposition", dependencies: ["CoreDomain", "DataContracts", "DataProviders", "Persistence", "SecuritySupport"], path: "Sources/AppComposition"),
        .executableTarget(name: "FoundationCodecProbe", dependencies: ["CoreDomain"], path: "Tools/FoundationCodecProbe"),
        .testTarget(name: "FoundationTests", dependencies: ["CoreDomain", "CoreCalculations", "DataContracts", "DataProviders", "Persistence", "SecuritySupport", "AppComposition", .product(name: "GRDB", package: "GRDB.swift")])
    ],
    swiftLanguageModes: [.v6]
)
