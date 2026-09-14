import CryptoKit
import Foundation
import IOKit

/// This Mac's identity towards the license service. The raw IOPlatformUUID
/// never leaves the process — only its SHA-256 goes over the wire.
public enum MachineIdentity {

    public static func machineId() -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? "unknown-platform-uuid"
        let digest = SHA256.hash(data: Data(uuid.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func machineName() -> String {
        Host.current().localizedName ?? "Mac"
    }
}

public enum LicenseClientError: Error, Equatable {
    case unknownKey       // 404
    case inactive         // 402 (refunded, or expired on activate)
    case activationLimit  // 409
    case rateLimited      // 429
    case badResponse(Int)
}

/// Thin JSON client for the license worker. Endpoints and payloads mirror
/// services/license-worker/README.md; entitlement strings are verified by
/// LicenseStore, not here.
public struct LicenseClient {

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    /// nil while the webhook has not landed yet — the app polls after checkout.
    public func byReference(_ reference: String) async throws -> String? {
        let url = baseURL.appendingPathComponent("license/by-reference/\(reference)")
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw Self.error(for: status) }
        return try JSONDecoder().decode([String: String].self, from: data)["key"]
    }

    public func activate(key: String, machineId: String, machineName: String) async throws -> String {
        try await entitlement(from: "activate", body: [
            "key": key, "machineId": machineId, "machineName": machineName,
        ])
    }

    public func validate(key: String, machineId: String) async throws -> String {
        try await entitlement(from: "validate", body: ["key": key, "machineId": machineId])
    }

    public func deactivate(key: String, machineId: String) async throws {
        _ = try await post("deactivate", body: ["key": key, "machineId": machineId])
    }

    public func recover(email: String) async throws {
        _ = try await post("recover", body: ["email": email])
    }

    // MARK: - Private

    private func entitlement(from path: String, body: [String: String]) async throws -> String {
        let data = try await post(path, body: body)
        guard let entitlement = try JSONDecoder()
            .decode([String: String].self, from: data)["entitlement"]
        else { throw LicenseClientError.badResponse(200) }
        return entitlement
    }

    private func post(_ path: String, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.error(for: status) }
        return data
    }

    private static func error(for status: Int) -> LicenseClientError {
        switch status {
        case 402: return .inactive
        case 404: return .unknownKey
        case 409: return .activationLimit
        case 429: return .rateLimited
        default: return .badResponse(status)
        }
    }
}
