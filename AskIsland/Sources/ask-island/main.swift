import Foundation
import AskIslandCore

func usage() -> Never {
    let text = """
    Usage:
      ask-island ask "<question>" [-o "<label>[::<description>]"]... [--multi] [--no-text] [--title T] [--detail D] [--header H] [--timeout S] [--agent A] [--json]
      ask-island do "<title>" [--detail D] [--kind computer|phone|password|login|other] [--timeout S] [--agent A] [--json]
      ask-island notify "<title>" [--detail D] [--agent A]
      ask-island hook
      ask-island mcp
    """
    fputs(text + "\n", stderr)
    exit(64)
}

func resolveAgent(flag: String?) -> String {
    if let flag = flag, !flag.isEmpty {
        return flag
    }
    let env = ProcessInfo.processInfo.environment
    if let agent = env["ASK_ISLAND_AGENT"], !agent.isEmpty {
        return agent
    }
    if env["CLAUDECODE"] == "1" {
        return "claude"
    }
    if env.keys.contains(where: { $0.hasPrefix("CODEX_") }) {
        return "codex"
    }
    return "cli"
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    usage()
}

switch command {
case "ask":
    var rest = Array(args.dropFirst())
    guard !rest.isEmpty, !rest[0].hasPrefix("-") else {
        usage()
    }
    let questionText = rest.removeFirst()
    var options: [AskOption] = []
    var multiSelect = false
    var allowText = true
    var title: String?
    var detail: String?
    var header: String?
    var timeout: Int?
    var agentFlag: String?
    var isJson = false

    var i = 0
    while i < rest.count {
        let arg = rest[i]
        switch arg {
        case "-o", "--option":
            i += 1
            guard i < rest.count else { usage() }
            let optStr = rest[i]
            if let r = optStr.range(of: "::") {
                let label = String(optStr[..<r.lowerBound])
                let desc = String(optStr[r.upperBound...])
                options.append(AskOption(label: label, description: desc))
            } else {
                options.append(AskOption(label: optStr))
            }
        case "--multi":
            multiSelect = true
        case "--no-text":
            allowText = false
        case "--title":
            i += 1
            guard i < rest.count else { usage() }
            title = rest[i]
        case "--detail":
            i += 1
            guard i < rest.count else { usage() }
            detail = rest[i]
        case "--header":
            i += 1
            guard i < rest.count else { usage() }
            header = rest[i]
        case "--timeout":
            i += 1
            guard i < rest.count, let t = Int(rest[i]) else { usage() }
            timeout = t
        case "--agent":
            i += 1
            guard i < rest.count else { usage() }
            agentFlag = rest[i]
        case "--json":
            isJson = true
        default:
            usage()
        }
        i += 1
    }

    let finalTitle = (title?.isEmpty == false) ? title! : questionText
    let agent = resolveAgent(flag: agentFlag)
    let cwd = FileManager.default.currentDirectoryPath
    let q = AskQuestion(header: header, question: questionText, options: options, multiSelect: multiSelect, allowText: allowText)
    let req = AskRequest(
        kind: .question,
        title: finalTitle,
        detail: detail,
        questions: [q],
        source: AskSource(agent: agent, cwd: cwd, session: nil),
        timeoutSeconds: timeout
    )

    await runClientRequest(req, isJson: isJson)

case "do":
    var rest = Array(args.dropFirst())
    guard !rest.isEmpty, !rest[0].hasPrefix("-") else {
        usage()
    }
    let actionTitle = rest.removeFirst()
    var detail: String?
    var actionKind: ActionKind?
    var timeout: Int?
    var agentFlag: String?
    var isJson = false

    var i = 0
    while i < rest.count {
        let arg = rest[i]
        switch arg {
        case "--detail":
            i += 1
            guard i < rest.count else { usage() }
            detail = rest[i]
        case "--kind":
            i += 1
            guard i < rest.count, let k = ActionKind(rawValue: rest[i]) else { usage() }
            actionKind = k
        case "--timeout":
            i += 1
            guard i < rest.count, let t = Int(rest[i]) else { usage() }
            timeout = t
        case "--agent":
            i += 1
            guard i < rest.count else { usage() }
            agentFlag = rest[i]
        case "--json":
            isJson = true
        default:
            usage()
        }
        i += 1
    }

    let agent = resolveAgent(flag: agentFlag)
    let cwd = FileManager.default.currentDirectoryPath
    let req = AskRequest(
        kind: .action,
        title: actionTitle,
        detail: detail,
        actionKind: actionKind,
        source: AskSource(agent: agent, cwd: cwd, session: nil),
        timeoutSeconds: timeout
    )

    await runClientRequest(req, isJson: isJson)

case "notify":
    var rest = Array(args.dropFirst())
    guard !rest.isEmpty, !rest[0].hasPrefix("-") else {
        usage()
    }
    let notifyTitle = rest.removeFirst()
    var detail: String?
    var agentFlag: String?

    var i = 0
    while i < rest.count {
        let arg = rest[i]
        switch arg {
        case "--detail":
            i += 1
            guard i < rest.count else { usage() }
            detail = rest[i]
        case "--agent":
            i += 1
            guard i < rest.count else { usage() }
            agentFlag = rest[i]
        default:
            usage()
        }
        i += 1
    }

    let agent = resolveAgent(flag: agentFlag)
    let cwd = FileManager.default.currentDirectoryPath
    let req = AskRequest(
        kind: .notify,
        title: notifyTitle,
        detail: detail,
        source: AskSource(agent: agent, cwd: cwd, session: nil)
    )

    await runClientRequest(req, isJson: false)

case "hook":
    // Claude Code hook: stdin JSON → stdout JSON
    // Never exit non-zero
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    guard let parsed = ClaudeHook.parseRequest(from: stdinData) else {
        exit(0)
    }

    let client = AskClient()
    guard await client.isRunning() else {
        exit(0)
    }

    do {
        let response = try await client.ask(parsed.request)
        if let outStr = ClaudeHook.formatResponse(request: parsed.request, response: response, rawInput: parsed.rawInput) {
            print(outStr)
        }
    } catch {
        // Claude falls back to its own UI
    }
    exit(0)

case "mcp":
    let client = AskClient()
    let server = MCPServer { req in
        try await client.ask(req)
    }
    await server.run()
    exit(0)

default:
    usage()
}

func runClientRequest(_ request: AskRequest, isJson: Bool) async {
    let client = AskClient()
    do {
        let response = try await client.ask(request)

        if isJson {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(response),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            switch request.kind {
            case .question:
                if response.status == .answered {
                    print(response.answers.first?.display ?? "")
                }
            case .action:
                if response.status == .done {
                    if let note = response.note, !note.isEmpty {
                        print(note)
                    }
                }
            case .notify:
                break
            }
        }

        switch response.status {
        case .answered, .done:
            exit(0)
        case .declined:
            if let note = response.note, !note.isEmpty {
                fputs("\(note)\n", stderr)
            }
            exit(3)
        case .timeout:
            exit(4)
        case .dismissed:
            if request.kind == .notify {
                exit(0)
            } else {
                exit(5)
            }
        }
    } catch let error as AskClientError {
        if error == .notRunning {
            fputs("AskIsland 没在运行\n", stderr)
            exit(2)
        } else {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
