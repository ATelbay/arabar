import Foundation
import os.log

@inline(__always)
func debugLog(_ log: OSLog, _ message: @autoclosure () -> String) {
    guard UserDefaults.standard.bool(forKey: "debug.cookies") else { return }
    os_log("%{private}@", log: log, type: .default, message())
}

@inline(__always)
func debugLog(_ log: OSLog, _ type: OSLogType, _ message: @autoclosure () -> String) {
    guard UserDefaults.standard.bool(forKey: "debug.cookies") else { return }
    os_log("%{private}@", log: log, type: type, message())
}
