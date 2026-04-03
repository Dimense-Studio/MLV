import Foundation
import os

enum AppLogger {
    static let subsystem = "dimense.net.MLV"

    static func category(_ name: String) -> Logger {
        Logger(subsystem: subsystem, category: name)
    }
}
