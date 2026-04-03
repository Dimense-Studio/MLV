import Foundation

enum AppEnvironment: String {
    case development = "development"
    case production = "production"
}

enum EnvironmentConfig {
    static var current: AppEnvironment {
        let value = ProcessInfo.processInfo.environment["MLV_ENV"]?.lowercased()
        return AppEnvironment(rawValue: value ?? "") ?? .development
    }

    static var isDevelopment: Bool {
        current == .development
    }
}
