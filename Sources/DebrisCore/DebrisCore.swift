import Foundation
import GRDB

/// Engine namespace. Catalogue, scanner, planner, journal and executor
/// arrive in Phase 1+. No UI in this module.
public enum DebrisCore {
    public static let version = "0.1.0"
}
