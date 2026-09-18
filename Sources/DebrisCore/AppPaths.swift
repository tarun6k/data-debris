import Foundation

/// Where the app keeps its state, and the one switch that moves all of it.
///
/// `APP_SUPPORT_OVERRIDE` (a directory path) relocates Application Support,
/// the LaunchAgents folder, and suffixes the Keychain service, the LaunchAgent
/// labels and the defaults domain with ".debug" so nothing collides with the
/// real app. Debug routes (`--screen …`, `--drive…`) must set it before any
/// store exists; a Debug build refuses to resolve a path for such a route
/// without it, so the real profile cannot be touched by accident.
public enum AppPaths {

    public static let overrideKey = "APP_SUPPORT_OVERRIDE"
    public static let bundleIdentifier = "com.tarunkumar.datadebris"

    /// Read live (not a cached snapshot): the app sets it during launch.
    public static var overrideDirectory: URL? {
        guard let raw = getenv(overrideKey) else { return nil }
        let path = String(cString: raw)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static var isOverridden: Bool { overrideDirectory != nil }

    private static var suffix: String { isOverridden ? ".debug" : "" }

    /// `~/Library/Application Support/DataDebris`, or the override. Created.
    public static func applicationSupportDirectory() throws -> URL {
        assertDebugRouteIsSandboxed()
        let dir = try overrideDirectory ?? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("DataDebris", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/LaunchAgents`, or `<override>/LaunchAgents`.
    public static func launchAgentsDirectory() -> URL {
        assertDebugRouteIsSandboxed()
        return overrideDirectory?.appendingPathComponent("LaunchAgents", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// kSecAttrService of the license item.
    public static var keychainService: String {
        assertDebugRouteIsSandboxed()
        return bundleIdentifier + ".license" + suffix
    }

    /// Label of the scheduled Auto Clean agent (low-space and retry derive from it).
    public static var launchAgentLabel: String {
        assertDebugRouteIsSandboxed()
        return bundleIdentifier + ".autoclean" + suffix
    }

    /// The app's defaults, or a ".debug" suite under the override.
    public static var userDefaults: UserDefaults {
        assertDebugRouteIsSandboxed()
        guard isOverridden else { return .standard }
        return UserDefaults(suiteName: bundleIdentifier + ".debug") ?? .standard
    }

    // MARK: - Debug-route guard

    /// `--screen <route>` and every `--drive…` flag.
    public static func isDebugRoute(_ arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix("--screen") || $0.hasPrefix("--drive") }
    }

    /// True when a debug route is running without an override — the case a
    /// Debug build refuses before it can write anywhere.
    public static func unsandboxedDebugRoute(arguments: [String] = CommandLine.arguments,
                                             override: URL? = overrideDirectory) -> Bool {
        isDebugRoute(arguments) && override == nil
    }

    private static func assertDebugRouteIsSandboxed() {
        #if DEBUG
        precondition(
            !unsandboxedDebugRoute(),
            "debug route without \(overrideKey): refusing to touch the real profile")
        #endif
    }
}
