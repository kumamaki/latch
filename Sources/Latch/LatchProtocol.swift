import Foundation

// Wire types for the DEBUG Latch socket. Same newline-JSON one-shot
// envelope so a CLI can `printf | nc -U`.

struct LatchRequest: Sendable, Decodable {
    let token: String
    let command: LatchCommand

    fileprivate enum CodingKeys: String, CodingKey {
        case token
        case command
        case args
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        let name = try container.decode(String.self, forKey: .command)
        self.command = try LatchCommand.decode(name: name, container: container)
    }
}

enum LatchCommand: Sendable {
    case ping
    case queryBoot
    case queryWindows
    case windowShow(name: String)
    case windowHide(name: String)
    case axDump(window: String?, labeled: Bool)
    case axFind(id: String)
    case axPress(id: String, action: String?)
    case axSet(id: String, value: String)
    case screenshot(window: String)

    fileprivate static func decode(
        name: String,
        container: KeyedDecodingContainer<LatchRequest.CodingKeys>
    ) throws -> Self {
        switch name {
        case "ping":
            return .ping
        case "queryBoot":
            return .queryBoot
        case "queryWindows":
            return .queryWindows
        case "windowShow":
            let args = try container.decode(WindowArgs.self, forKey: .args)
            return .windowShow(name: args.window)
        case "windowHide":
            let args = try container.decode(WindowArgs.self, forKey: .args)
            return .windowHide(name: args.window)
        case "axDump":
            let args = try container.decodeIfPresent(AxDumpArgs.self, forKey: .args)
            return .axDump(window: args?.window, labeled: args?.labeled ?? false)
        case "axFind":
            let args = try container.decode(AxIdArgs.self, forKey: .args)
            return .axFind(id: args.id)
        case "axPress":
            let args = try container.decode(AxPressArgs.self, forKey: .args)
            return .axPress(id: args.id, action: args.action)
        case "axSet":
            let args = try container.decode(AxSetArgs.self, forKey: .args)
            return .axSet(id: args.id, value: args.value)
        case "screenshot":
            let args = try container.decode(WindowArgs.self, forKey: .args)
            return .screenshot(window: args.window)
        default:
            throw LatchError.unknownCommand(name: name)
        }
    }

    private struct WindowArgs: Decodable {
        let window: String
    }

    private struct AxDumpArgs: Decodable {
        let window: String?
        let labeled: Bool?
    }

    private struct AxIdArgs: Decodable {
        let id: String
    }

    private struct AxPressArgs: Decodable {
        let id: String
        let action: String?
    }

    private struct AxSetArgs: Decodable {
        let id: String
        let value: String
    }
}

enum LatchResponse: Sendable, Encodable {
    case success(LatchResponseData)
    case failure(LatchResponseError)

    static func success() -> Self { .success(.empty) }

    private enum CodingKeys: String, CodingKey {
        case ok, data, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let data):
            try container.encode(true, forKey: .ok)
            try container.encode(data, forKey: .data)
        case .failure(let error):
            try container.encode(false, forKey: .ok)
            try container.encode(error, forKey: .error)
        }
    }
}

enum LatchResponseData: Sendable, Encodable {
    case empty
    case pong
    case boot(state: String)
    case windows(items: [LatchWindowStatus])
    case axTree(root: LatchAXNode)
    case axNode(LatchAXNode)
    case screenshot(path: String)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .empty:
            var container = encoder.singleValueContainer()
            try container.encode([String: String]())
        case .pong:
            var container = encoder.container(keyedBy: PongKeys.self)
            try container.encode("ok", forKey: .status)
        case .boot(let state):
            var container = encoder.container(keyedBy: BootKeys.self)
            try container.encode(state, forKey: .state)
        case .windows(let items):
            var container = encoder.container(keyedBy: WindowsKeys.self)
            try container.encode(items, forKey: .items)
        case .axTree(let root):
            var container = encoder.container(keyedBy: TreeKeys.self)
            try container.encode(root, forKey: .root)
        case .axNode(let node):
            var container = encoder.container(keyedBy: NodeKeys.self)
            try container.encode(node, forKey: .node)
        case .screenshot(let path):
            var container = encoder.container(keyedBy: ScreenshotKeys.self)
            try container.encode(path, forKey: .path)
        }
    }

    private enum PongKeys: String, CodingKey { case status }
    private enum BootKeys: String, CodingKey { case state }
    private enum WindowsKeys: String, CodingKey { case items }
    private enum TreeKeys: String, CodingKey { case root }
    private enum NodeKeys: String, CodingKey { case node }
    private enum ScreenshotKeys: String, CodingKey { case path }
}

public struct LatchWindowStatus: Sendable, Encodable, Equatable {
    public let name: String
    public let visible: Bool
    public let exists: Bool

    public init(name: String, visible: Bool, exists: Bool) {
        self.name = name
        self.visible = visible
        self.exists = exists
    }
}

public struct LatchAXNode: Sendable, Encodable, Equatable {
    public let id: String?
    public let role: String
    public let title: String?
    public let value: String?
    public let enabled: Bool
    public let actions: [String]
    public let frame: LatchAXFrame
    public let children: [Self]
    public let window: String?
    public let kind: LatchCatalog.Kind?
    public let choices: [String]?
    public let description: String?

    public init(
        id: String?,
        role: String,
        title: String?,
        value: String?,
        enabled: Bool,
        actions: [String],
        frame: LatchAXFrame,
        children: [Self],
        window: String? = nil,
        kind: LatchCatalog.Kind? = nil,
        choices: [String]? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.enabled = enabled
        self.actions = actions
        self.frame = frame
        self.children = children
        self.window = window
        self.kind = kind
        self.choices = choices
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, title, value, enabled, actions, frame, children
        case window, kind, choices, description
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(title, forKey: .title)
        try container.encode(value, forKey: .value)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(actions, forKey: .actions)
        try container.encode(frame, forKey: .frame)
        try container.encode(children, forKey: .children)
        try container.encodeIfPresent(window, forKey: .window)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(choices, forKey: .choices)
        try container.encodeIfPresent(description, forKey: .description)
    }
}

public struct LatchAXFrame: Sendable, Encodable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

enum LatchErrorCode: String, Sendable, Encodable {
    case unauthenticated
    case unknownCommand
    case ipc
    case notFound
    case unavailable
    case `protocol`
}

struct LatchResponseError: Sendable, Encodable {
    let code: LatchErrorCode
    let message: String
}
