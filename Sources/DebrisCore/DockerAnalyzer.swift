import Foundation

/// Dangling images and unused build cache, as `docker system df -v` reports
/// them (product spec §6). Not a file analyzer: it runs once after the walk,
/// and only when the catalogue carries its rule — Auto Clean's cut-down
/// catalogue never does (S2/S9). Every failure — no docker, daemon not
/// running, timeout, a remote context, unreadable output — yields no
/// findings rather than an error: unknown is untouched (S1).
public struct DockerAnalyzer: Sendable {

    public static let ruleId = "dev.docker.dangling"
    public static let diskUsageArguments = ["system", "df", "-v", "--format", "json"]

    public enum ParseError: Error, Equatable {
        case notAnObject
    }

    public let rule: Rule
    public let cli: DockerCLI?
    public let timeout: TimeInterval

    public init(rule: Rule, cli: DockerCLI?, timeout: TimeInterval = 10) {
        self.rule = rule
        self.cli = cli
        self.timeout = timeout
    }

    public func findings(now: Date = Date()) async -> [Finding] {
        guard let cli else { return [] }
        let data: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.diskUsage(cli, timeout: timeout))
            }
        }
        guard let data else { return [] }
        return (try? Self.parse(data, rule: rule, now: now)) ?? []
    }

    /// Raw `docker system df -v --format json` output, or nil for any of the
    /// "no findings" conditions.
    static func diskUsage(_ cli: DockerCLI, timeout: TimeInterval) -> Data? {
        guard cli.endpointIsLocalSocket(timeout: min(timeout, 3)) else { return nil }
        return try? cli.run(diskUsageArguments, timeout: timeout)
    }

    // MARK: - Parsing

    /// `docker system df -v --format json` is one object with "Images",
    /// "Containers", "Volumes" and "BuildCache" arrays whose fields are the
    /// strings the CLI's own tables show. Sizes are therefore docker's
    /// three-significant-figure numbers, not byte counts (S10: the number
    /// docker reports as reclaimable, never a virtual size).
    public static func parse(_ data: Data, rule: Rule, now: Date = Date()) throws -> [Finding] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notAnObject
        }
        var out: [Finding] = []

        for entry in root["Images"] as? [[String: Any]] ?? [] {
            guard let id = string(entry["ID"]).map(stripDigestPrefix), DockerObject.isValid(id: id) else { continue }
            // Dangling: no repository and no tag. `docker system df` cannot
            // tell a digest-only pull from a leftover, so both qualify; an
            // image with a container (even stopped) stays. "N/A" counts as
            // unknown, and unknown is untouched.
            guard string(entry["Repository"]) == "<none>", string(entry["Tag"]) == "<none>",
                  string(entry["Containers"]) == "0" else { continue }
            // Reclaimable bytes are the layers nothing else shares; without
            // that number the honest size is unknown, so the image is skipped.
            guard let size = string(entry["UniqueSize"]).flatMap(bytes(fromHumanSize:)) else { continue }
            out.append(make(
                rule: rule, object: .image(id: id), size: size,
                created: string(entry["CreatedAt"]).flatMap(date(fromGoTime:)) ?? now,
                lastUsed: nil,
                reason: "Untagged image no container uses."))
        }

        for entry in root["BuildCache"] as? [[String: Any]] ?? [] {
            guard let id = string(entry["ID"]), DockerObject.isValid(id: id) else { continue }
            guard string(entry["InUse"]) == "false" else { continue }
            // A shared record's blob also backs an image layer: removing the
            // record frees nothing, so it is reported as 0 and the rule's
            // size floor drops it (S10).
            let shared = string(entry["Shared"]) == "true"
            guard let size = shared ? 0 : string(entry["Size"]).flatMap(bytes(fromHumanSize:)) else { continue }
            let type = string(entry["CacheType"]).map { " (\($0))" } ?? ""
            out.append(make(
                rule: rule, object: .buildCache(id: id), size: size,
                created: string(entry["CreatedAt"]).flatMap(date(fromGoTime:)) ?? now,
                lastUsed: string(entry["LastUsedAt"]).flatMap(date(fromGoTime:)),
                reason: "Build cache\(type) no build is using."))
        }

        return out
            .filter { satisfies(rule.predicates, $0, now: now) }
            .sorted { $0.allocatedSize > $1.allocatedSize }
    }

    private static func make(
        rule: Rule, object: DockerObject, size: Int64, created: Date, lastUsed: Date?, reason: String
    ) -> Finding {
        Finding(
            ruleId: rule.id,
            url: object.url,
            size: size,
            allocatedSize: size,
            mtime: created,
            lastOpened: lastUsed,
            level: rule.level,
            category: rule.category,
            reason: reason,
            consequence: rule.consequence,
            ownerBundleId: rule.owner,
            isReclaimable: size > 0)
    }

    private static func satisfies(_ predicates: [Predicate], _ finding: Finding, now: Date) -> Bool {
        predicates.allSatisfy { predicate in
            switch predicate {
            case .sizeAtLeastBytes(let bytes):
                return finding.size >= bytes
            case .mtimeOlderThanDays(let days):
                return now.timeIntervalSince(finding.mtime) >= Double(days) * 86_400
            case .lastOpenedOlderThanDays(let days):
                return now.timeIntervalSince(finding.lastOpened ?? finding.mtime) >= Double(days) * 86_400
            case .ownerBundleRunning:
                return true
            }
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let number = value as? NSNumber else { return nil }
        if number === kCFBooleanTrue { return "true" }
        if number === kCFBooleanFalse { return "false" }
        return number.stringValue
    }

    private static func stripDigestPrefix(_ id: String) -> String {
        id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id
    }

    /// "1.23GB", "456MB", "3.2kB", "0B" → bytes, decimal units as docker
    /// prints them; "1.5GiB"-style binary units are accepted too.
    public static func bytes(fromHumanSize text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased()
        guard !number.isEmpty, let value = Double(number) else { return nil }
        let multiplier: Double
        switch unit {
        case "", "b": multiplier = 1
        case "kb": multiplier = 1e3
        case "mb": multiplier = 1e6
        case "gb": multiplier = 1e9
        case "tb": multiplier = 1e12
        case "pb": multiplier = 1e15
        case "kib": multiplier = 1024
        case "mib": multiplier = 1024 * 1024
        case "gib": multiplier = 1024 * 1024 * 1024
        case "tib": multiplier = 1024 * 1024 * 1024 * 1024
        case "pib": multiplier = 1024 * 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64((value * multiplier).rounded())
    }

    /// Go's `time.Time.String()`: "2026-05-01 10:00:00 +0000 UTC", with
    /// optional fractional seconds and a trailing zone name.
    public static func date(fromGoTime text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let clock = parts[1].split(separator: ".").first.map(String.init) ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: "\(parts[0]) \(clock) \(parts[2])")
    }
}
