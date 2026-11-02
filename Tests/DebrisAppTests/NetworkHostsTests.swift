import XCTest
@testable import DataDebris

/// The privacy promise: the app talks to exactly two hosts, the update feed
/// and the license service. A static check over Sources/ plus the built
/// bundle, so a stray URLSession call or an SDK cannot slip in unnoticed.
final class NetworkHostsTests: XCTestCase {
    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private func swiftFiles() throws -> [(relative: String, lines: [String])] {
        let root = Self.sourcesRoot
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Sources/ not reachable from \(root.path)")
        }
        var files: [(String, [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url)
            let relative = String(url.path.dropFirst(root.path.count + 1))
            files.append((relative, text.components(separatedBy: "\n")))
        }
        XCTAssertGreaterThan(files.count, 20, "walked the wrong folder")
        return files.sorted { $0.0 < $1.0 }
    }

    private func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    func testEveryLiteralHostIsTheFeedOrTheLicenseService() throws {
        let configs = [try AppConfig.load(variant: .debug), try AppConfig.load(variant: .release)]
        var allowed = Set(configs.flatMap { [$0.updateFeedURL.host, $0.licenseWorkerURL.host] }.compactMap { $0 })
        allowed.insert("127.0.0.1") // the checkout page server, loopback only
        let regex = try NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]+)"#)

        var offenders: [String] = []
        for (relative, lines) in try swiftFiles() {
            for (index, line) in lines.enumerated() where !isComment(line) {
                let range = NSRange(line.startIndex..., in: line)
                for match in regex.matches(in: line, range: range) {
                    let host = String(line[Range(match.range(at: 1), in: line)!])
                    if !allowed.contains(host) { offenders.append("\(relative):\(index + 1) \(host)") }
                }
            }
        }
        XCTAssertEqual(offenders, [], "hosts outside the privacy promise (allowed: \(allowed.sorted()))")
    }

    func testNetworkAPIsLiveOnlyInTheAllowlistedFiles() throws {
        // File → why it may touch the network stack.
        let allowed: [String: String] = [
            "DebrisCore/Licensing/LicenseClient.swift": "license service and pricing proxy (URLSession)",
            "DebrisApp/Updates/UpdateManager.swift": "Sparkle updater (feed host)",
            "DebrisApp/Purchase/CheckoutServer.swift": "loopback NWListener serving the checkout page",
            "DebrisApp/Purchase/PrivacySecuritySheet.swift": "NWPathMonitor reachability, no traffic",
            // Subprocesses are listed so a `curl` could not hide in one.
            "DebrisCore/AutoClean/LaunchAgentManager.swift": "Process: /bin/launchctl",
            "DebrisCore/AutoClean/AutoCleanRunner.swift": "Process: /usr/bin/tmutil status",
        ]
        let markers = ["URLSession", "NSURLConnection", "NWConnection", "NWListener", "NWPathMonitor",
                       "import Network", "import Sparkle", "CFStream", "WKWebView", "getaddrinfo",
                       "socket(", "Process("]
        var offenders: [String] = []
        for (relative, lines) in try swiftFiles() where allowed[relative] == nil {
            for (index, line) in lines.enumerated() where !isComment(line) {
                for marker in markers where line.contains(marker) {
                    offenders.append("\(relative):\(index + 1) \(marker)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "network API outside the allowlist")
    }

    /// The built bundle links nothing but our own framework and Sparkle.
    /// Xcode 16 (the CI runner) copies its own test-run support into the
    /// hosted app's Frameworks folder (XCTest*, XCUI*, XCUnit, Testing,
    /// libXCTest*); Xcode 27 does not. Those are Xcode's, not ours.
    func testBundledFrameworksAreOnlyCoreAndSparkle() throws {
        let frameworks = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks")
        let names = try FileManager.default.contentsOfDirectory(atPath: frameworks.path)
            .filter { !$0.hasPrefix(".") && !Self.isXcodeTestSupport($0) }.sorted()
        XCTAssertEqual(names, ["DebrisCore.framework", "Sparkle.framework"])
    }

    static func isXcodeTestSupport(_ name: String) -> Bool {
        name.hasPrefix("XC") || name.hasPrefix("libXC") || name == "Testing.framework"
    }

    func testXcodeTestSupportFilterLeavesOurFrameworksAlone() {
        for name in ["XCTest.framework", "XCUIAutomation.framework", "XCUnit.framework",
                     "libXCTestBundleInject.dylib", "libXCTestSwiftSupport.dylib", "Testing.framework"] {
            XCTAssertTrue(Self.isXcodeTestSupport(name), name)
        }
        for name in ["DebrisCore.framework", "Sparkle.framework", "libcurl.dylib", "Alamofire.framework"] {
            XCTAssertFalse(Self.isXcodeTestSupport(name), name)
        }
    }
}
