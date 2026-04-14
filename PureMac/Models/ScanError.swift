import Foundation

enum ScanError: LocalizedError {
    case permissionDenied(path: String)
    case directoryEnumerationFailed(path: String, underlying: Error)
    case processExecutionFailed(tool: String, underlying: Error)
    case invalidData(context: String)
    case helperToolUnavailable
    case operationCancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let path):
            return "Permission denied when accessing '\(path)'. Grant Full Disk Access in System Settings."
        case .directoryEnumerationFailed(let path, let underlying):
            return "Failed to enumerate directory '\(path)': \(underlying.localizedDescription)"
        case .processExecutionFailed(let tool, let underlying):
            return "Failed to execute '\(tool)': \(underlying.localizedDescription)"
        case .invalidData(let context):
            return "Invalid data encountered: \(context)"
        case .helperToolUnavailable:
            return "The privileged helper tool is not installed or unavailable."
        case .operationCancelled:
            return "The operation was cancelled."
        }
    }
}
