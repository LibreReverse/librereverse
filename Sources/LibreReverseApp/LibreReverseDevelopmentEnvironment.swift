import Foundation

/// UI fixtures and developer overrides must not alter the installed release's
/// data directory, startup permissions, capture settings, or shutdown path.
enum LibreReverseDevelopmentEnvironment {
    static var values: [String: String] {
        #if DEBUG
        ProcessInfo.processInfo.environment
        #else
        [:]
        #endif
    }
}
