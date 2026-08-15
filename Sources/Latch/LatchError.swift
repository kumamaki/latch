import Foundation

/// Failure modes the DEBUG Latch socket can produce.
public enum LatchError: Error, Sendable, CustomStringConvertible {
    case homeDirectoryUnavailable
    case socketPathTooLong(path: String, limit: Int)
    case directoryCreate(path: String, underlying: String)
    case socketCreate(errno: Int32)
    case socketBind(path: String, errno: Int32)
    case socketListen(errno: Int32)
    case recvFailed(errno: Int32)
    case sendFailed(errno: Int32)
    case encodeFailed(underlying: String)
    case tokenIO(underlying: String)
    case malformedRequest(reason: String)
    case unauthenticated
    case unknownCommand(name: String)
    case unknownWindow(name: String)
    case windowNotVisible(name: String)
    case windowEmpty(name: String)
    case screenshotFailed(reason: String)
    case elementNotFound(id: String)
    case actionUnavailable(id: String, action: String)
    case invalidValue(id: String, value: String, expected: String)
    case coreNotReady
    case opsUnavailable(reason: String)

    public var description: String {
        switch self {
        case .homeDirectoryUnavailable:
            return "Could not resolve $HOME for the current user."
        case .socketPathTooLong(let path, let limit):
            return "Socket path \(path) exceeds sun_path limit (\(limit) bytes)."
        case .directoryCreate(let path, let underlying):
            return "Failed to create \(path): \(underlying)."
        case .socketCreate(let errno):
            return "socket(2) failed with errno \(errno)."
        case .socketBind(let path, let errno):
            return "bind(2) on \(path) failed with errno \(errno)."
        case .socketListen(let errno):
            return "listen(2) failed with errno \(errno)."
        case .recvFailed(let errno):
            return "recv(2) failed with errno \(errno)."
        case .sendFailed(let errno):
            return "send(2) failed with errno \(errno)."
        case .encodeFailed(let underlying):
            return "Failed to encode Latch response: \(underlying)."
        case .tokenIO(let underlying):
            return "Latch token file failed: \(underlying)."
        case .malformedRequest(let reason):
            return "Malformed Latch request: \(reason)."
        case .unauthenticated:
            return "Latch request rejected: invalid token."
        case .unknownCommand(let name):
            return "Unknown Latch command: \(name)."
        case .unknownWindow(let name):
            return "Unknown window: \(name)."
        case .windowNotVisible(let name):
            return "Window \(name) is not visible."
        case .windowEmpty(let name):
            return "Window \(name) has no content to photograph."
        case .screenshotFailed(let reason):
            return "Screenshot failed: \(reason)."
        case .elementNotFound(let id):
            return "No catalog or accessibility element with id \(id)."
        case .actionUnavailable(let id, let action):
            return "Element \(id) cannot \(action)."
        case .invalidValue(let id, let value, let expected):
            return "Element \(id) expected \(expected), got \(value)."
        case .coreNotReady:
            return "App is not ready."
        case .opsUnavailable(let reason):
            return reason
        }
    }
}

extension LatchError {
    public init(_ error: LatchCatalog.Error) {
        switch error {
        case .notFound(let id):
            self = .elementNotFound(id: id)
        case .actionUnavailable(let id, let action):
            self = .actionUnavailable(id: id, action: action)
        case .invalidValue(let id, let value, let expected):
            self = .invalidValue(id: id, value: value, expected: expected)
        case .duplicate:
            self = .opsUnavailable(reason: error.description)
        }
    }

    init(_ error: UnixSocketError) {
        switch error {
        case .socketPathTooLong(let path, let limit):
            self = .socketPathTooLong(path: path, limit: limit)
        case .directoryCreate(let path, let underlying):
            self = .directoryCreate(path: path, underlying: underlying)
        case .socketCreate(let errno):
            self = .socketCreate(errno: errno)
        case .socketBind(let path, let errno):
            self = .socketBind(path: path, errno: errno)
        case .socketListen(let errno):
            self = .socketListen(errno: errno)
        }
    }
}
