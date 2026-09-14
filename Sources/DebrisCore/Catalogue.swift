import Foundation

public enum CatalogueError: Error, Equatable {
    case missingBundledCatalogue
}

/// The versioned, declarative rule set. Bundled with the framework and
/// updated only through app releases — never fetched over the network.
public struct Catalogue: Codable, Equatable, Sendable {
    public let version: Int
    public let rules: [Rule]

    public init(version: Int, rules: [Rule]) {
        self.version = version
        self.rules = rules
    }

    public static func load(from data: Data) throws -> Catalogue {
        try JSONDecoder().decode(Catalogue.self, from: data)
    }

    public static func load(from url: URL) throws -> Catalogue {
        try load(from: Data(contentsOf: url))
    }

    public static func bundled() throws -> Catalogue {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: BundleToken.self)
        #endif
        guard let url = bundle.url(forResource: "catalogue", withExtension: "json") else {
            throw CatalogueError.missingBundledCatalogue
        }
        return try load(from: url)
    }
}

#if !SWIFT_PACKAGE
private final class BundleToken {}
#endif
