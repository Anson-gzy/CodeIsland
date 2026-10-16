import Foundation

/// What the agent needs from the person.
public enum AskKind: String, Codable, Sendable {
    /// Pick options and/or type an answer; the agent waits for it.
    case question
    /// Do something by hand (on the Mac, the phone, type a password, log in), then tick "done".
    case action
    /// Just tell the person; returns immediately, nothing to answer.
    case notify
}

/// Icon / wording hint for `.action`. Passwords are never typed into the island:
/// the person types them where the detail says, then ticks done.
public enum ActionKind: String, Codable, Sendable {
    case computer, phone, password, login, other
}

public struct AskOption: Codable, Hashable, Sendable {
    public var label: String
    public var description: String?
    public init(label: String, description: String? = nil) {
        self.label = label; self.description = description
    }
}

public struct AskQuestion: Codable, Hashable, Sendable {
    public var header: String?
    public var question: String
    public var options: [AskOption]
    public var multiSelect: Bool
    /// Show a free-text field ("其他"). With no options this is the only input.
    public var allowText: Bool
    public init(header: String? = nil, question: String, options: [AskOption] = [],
                multiSelect: Bool = false, allowText: Bool = true) {
        self.header = header; self.question = question; self.options = options
        self.multiSelect = multiSelect; self.allowText = allowText
    }
}

public struct AskSource: Codable, Hashable, Sendable {
    /// "claude", "codex", "pi", "antigravity", "script", …
    public var agent: String?
    public var cwd: String?
    public var session: String?
    public init(agent: String? = nil, cwd: String? = nil, session: String? = nil) {
        self.agent = agent; self.cwd = cwd; self.session = session
    }
}

public struct AskRequest: Codable, Identifiable, Hashable, Sendable {
    /// Clients may leave it empty; the server assigns a UUID string.
    public var id: String
    public var kind: AskKind
    /// One line: what is needed ("选一个部署目标", "在 iPhone 上点允许").
    public var title: String
    /// What exactly the person has to do, plain text with line breaks / "1. 2." steps.
    public var detail: String?
    /// `.question` only; at least one.
    public var questions: [AskQuestion]
    /// `.action` only.
    public var actionKind: ActionKind?
    public var source: AskSource?
    /// nil = wait forever. On expiry the response status is `.timeout`.
    public var timeoutSeconds: Int?
    public var createdAt: Date

    public init(id: String = "", kind: AskKind, title: String, detail: String? = nil,
                questions: [AskQuestion] = [], actionKind: ActionKind? = nil,
                source: AskSource? = nil, timeoutSeconds: Int? = nil, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
        self.questions = questions; self.actionKind = actionKind; self.source = source
        self.timeoutSeconds = timeoutSeconds; self.createdAt = createdAt
    }
}

public enum AskStatus: String, Codable, Sendable {
    /// `.question` submitted.
    case answered
    /// `.action` ticked "我已完成".
    case done
    /// Person pressed "做不了 / 拒绝"; `note` may say why.
    case declined
    /// `timeoutSeconds` elapsed.
    case timeout
    /// Closed without answering, or `.notify` delivered.
    case dismissed
}

public struct AskAnswer: Codable, Hashable, Sendable {
    /// Selected option labels, in option order.
    public var selected: [String]
    /// Free text, nil when empty.
    public var text: String?
    public init(selected: [String] = [], text: String? = nil) {
        self.selected = selected; self.text = text
    }
    /// "A, B" or "A, B; text" or "text" — the form Claude's AskUserQuestion expects.
    public var display: String {
        var parts = selected.joined(separator: ", ")
        if let text, !text.isEmpty { parts = parts.isEmpty ? text : parts + "; " + text }
        return parts
    }
}

public struct AskResponse: Codable, Hashable, Sendable {
    public var id: String
    public var status: AskStatus
    /// One per question, same order as `AskRequest.questions`. Empty unless `.answered`.
    public var answers: [AskAnswer]
    /// Free note for actions ("已登录，但验证码没收到").
    public var note: String?
    public init(id: String, status: AskStatus, answers: [AskAnswer] = [], note: String? = nil) {
        self.id = id; self.status = status; self.answers = answers; self.note = note
    }
}

/// Written by the app at launch to `~/.ask-island/endpoint.json` (0600); read by clients.
public struct AskEndpoint: Codable, Hashable, Sendable {
    public var port: UInt16
    public var token: String
    public var pid: Int32
    public init(port: UInt16, token: String, pid: Int32) {
        self.port = port; self.token = token; self.pid = pid
    }
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ask-island/endpoint.json")
    }
}
