// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "MarketDecision",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MarketDecisionFoundation", targets: ["AppComposition"]),
               .library(name: "SECNetworkBroker", targets: ["SECNetworkBroker"]),
               .library(name: "EquityNetworkBroker", targets: ["EquityNetworkBroker"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "CoreDomain", dependencies: [], path: "Sources/CoreDomain"),
        .target(name: "CoreCalculations", dependencies: ["CoreDomain"], path: "Sources/CoreCalculations"),
        .target(name: "DataContracts", dependencies: ["CoreDomain"], path: "Sources/DataContracts"),
        .target(name: "DataProviders", dependencies: ["CoreDomain", "DataContracts"], path: "Sources/DataProviders"),
        .target(name: "SECNetworkBroker", dependencies: ["DataProviders"], path: "Sources/SECNetworkBroker"),
        .target(name: "EquityNetworkBroker", dependencies: ["CoreDomain", "DataContracts", "DataProviders"], path: "Sources/EquityNetworkBroker"),
        .target(name: "SECProvider", dependencies: ["CoreDomain", "DataContracts", "DataProviders"], path: "Sources/SECProvider"),
        .target(name: "MarketDataProviders", dependencies: ["CoreDomain", "DataContracts", "DataProviders"], path: "Sources/MarketDataProviders",
                resources: [.process("Resources")]),
        .target(name: "MacroProviders", dependencies: ["CoreDomain", "CoreCalculations", "DataContracts", "DataProviders", "MarketAnalytics"], path: "Sources/MacroProviders"),
        .target(name: "MarketAnalytics", dependencies: ["CoreDomain", "CoreCalculations", "DataContracts"], path: "Sources/MarketAnalytics"),
        .target(name: "FundamentalsEngine", dependencies: ["CoreDomain", "CoreCalculations", "DataContracts"], path: "Sources/FundamentalsEngine"),
        .target(name: "OptionsAnalytics", dependencies: ["CoreDomain", "CoreCalculations", "DataContracts"], path: "Sources/OptionsAnalytics"),
        .target(name: "BacktestEngine", dependencies: ["CoreCalculations", "DataContracts"], path: "Sources/BacktestEngine"),
        .target(name: "PortfolioEngine", dependencies: ["CoreDomain", "CoreCalculations", "DataContracts", "OptionsAnalytics", "MarketAnalytics"], path: "Sources/PortfolioEngine"),
        .target(name: "DecisionJournal", dependencies: ["CoreDomain", "DataContracts"], path: "Sources/DecisionJournal"),
        .target(name: "AlertEngine", dependencies: ["CoreDomain", "DataContracts"], path: "Sources/AlertEngine"),
        .target(name: "Persistence", dependencies: ["MacroProviders", "CoreDomain", "DataContracts", "DataProviders", "FundamentalsEngine", "PortfolioEngine", "OptionsAnalytics", "MarketAnalytics", .product(name: "GRDB", package: "GRDB.swift")], path: "Sources/Persistence"),
        .target(name: "SecuritySupport", dependencies: [], path: "Sources/Security"),
        .target(name: "AIInsights", dependencies: ["CoreDomain", "DataContracts"], path: "Sources/AIInsights"),
        .target(name: "UIComponents", dependencies: [], path: "Sources/UIComponents"),
        .target(name: "AppComposition", dependencies: ["MacroProviders", "CoreDomain", "DataContracts", "DataProviders", "SECProvider", "SECNetworkBroker", "EquityNetworkBroker", "MarketDataProviders", "Persistence", "SecuritySupport", "FundamentalsEngine", "PortfolioEngine", "OptionsAnalytics", "MarketAnalytics"], path: "Sources/AppComposition",
                resources: [.process("Resources")]),
        .executableTarget(name: "FoundationCodecProbe", dependencies: ["CoreDomain"], path: "Tools/FoundationCodecProbe"),
        .executableTarget(name: "SECNetworkIsolationProbe", dependencies: ["SECNetworkBroker", "EquityNetworkBroker"], path: "Tools/SECNetworkIsolationProbe"),
        .testTarget(name: "FoundationTests", dependencies: ["MacroProviders", "CoreDomain", "CoreCalculations", "DataContracts", "DataProviders", "SECProvider", "SECNetworkBroker", "EquityNetworkBroker", "MarketDataProviders", "FundamentalsEngine", "PortfolioEngine", "OptionsAnalytics", "MarketAnalytics", "Persistence", "SecuritySupport", "AppComposition", .product(name: "GRDB", package: "GRDB.swift")], resources: [.process("Resources")])
    ],
    swiftLanguageModes: [.v6]
)
