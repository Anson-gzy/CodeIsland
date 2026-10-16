import Foundation

public actor MCPOutputWriter {
    private let handle: FileHandle

    public init(handle: FileHandle) {
        self.handle = handle
    }

    public func write(_ string: String) {
        if let data = (string + "\n").data(using: .utf8) {
            handle.write(data)
        }
    }
}

/// JSON-RPC 2.0 stdio MCP server for AskIsland.
public final class MCPServer: Sendable {
    public typealias AskHandler = @Sendable (AskRequest) async throws -> AskResponse
    private let askHandler: AskHandler

    public init(ask: @escaping AskHandler) {
        self.askHandler = ask
    }

    /// Handles a single JSON-RPC line. Returns response JSON string if a reply is expected.
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return await handle(message: dict)
    }

    /// Handles a parsed JSON-RPC message dictionary.
    public func handle(message: [String: Any]) async -> String? {
        guard let method = message["method"] as? String else {
            return nil
        }

        // Notifications (e.g. notifications/* or messages with no id) receive no reply
        if method.hasPrefix("notifications/") || message["id"] == nil {
            return nil
        }

        let id = message["id"]!

        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            let clientVersion = params?["protocolVersion"] as? String
            let protocolVersion = clientVersion ?? "2025-06-18"

            let result: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "protocolVersion": protocolVersion,
                    "capabilities": [
                        "tools": [:]
                    ],
                    "serverInfo": [
                        "name": "ask-island",
                        "version": "0.1.0"
                    ]
                ]
            ]
            return serialize(result)

        case "ping":
            let result: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [:]
            ]
            return serialize(result)

        case "tools/list":
            let tools: [[String: Any]] = [
                [
                    "name": "ask_user",
                    "description": "需要用户做选择或回答问题时用（比在对话里问更显眼，用户不在终端前也能看到）",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string"],
                            "options": [
                                "type": "array",
                                "items": [
                                    "anyOf": [
                                        ["type": "string"],
                                        [
                                            "type": "object",
                                            "properties": [
                                                "label": ["type": "string"],
                                                "description": ["type": "string"]
                                            ],
                                            "required": ["label"]
                                        ]
                                    ]
                                ]
                            ],
                            "multi_select": ["type": "boolean"],
                            "allow_text": ["type": "boolean", "default": true],
                            "title": ["type": "string"],
                            "detail": ["type": "string"],
                            "timeout_seconds": ["type": "integer"]
                        ],
                        "required": ["question"]
                    ]
                ],
                [
                    "name": "request_user_action",
                    "description": "需要用户亲手操作电脑/手机、输入密码、登录、插线、点确认时用；会等到用户勾选已完成。不要让用户把密码告诉你",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "detail": [
                                "type": "string",
                                "description": "要用户做什么，写成步骤"
                            ],
                            "kind": [
                                "type": "string",
                                "enum": ["computer", "phone", "password", "login", "other"]
                            ],
                            "timeout_seconds": ["type": "integer"]
                        ],
                        "required": ["title", "detail"]
                    ]
                ],
                [
                    "name": "notify_user",
                    "description": "只通知、不需要回答时用（任务完成、需要用户回来看一眼）",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "detail": ["type": "string"]
                        ],
                        "required": ["title"]
                    ]
                ]
            ]

            let result: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "tools": tools
                ]
            ]
            return serialize(result)

        case "tools/call":
            let params = message["params"] as? [String: Any]
            let toolName = params?["name"] as? String ?? ""
            let args = (params?["arguments"] as? [String: Any]) ?? [:]
            return await handleToolCall(id: id, toolName: toolName, arguments: args)

        default:
            // Unknown method: error -32601
            let result: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "error": [
                    "code": -32601,
                    "message": "Method not found"
                ]
            ]
            return serialize(result)
        }
    }

    private func handleToolCall(id: Any, toolName: String, arguments: [String: Any]) async -> String? {
        switch toolName {
        case "ask_user":
            guard let questionText = arguments["question"] as? String, !questionText.isEmpty else {
                return serialize(toolResult(id: id, isError: true, text: "参数错误：question 不能为空"))
            }

            var options: [AskOption] = []
            if let rawOpts = arguments["options"] as? [Any] {
                for rawOpt in rawOpts {
                    if let str = rawOpt as? String {
                        options.append(AskOption(label: str))
                    } else if let dict = rawOpt as? [String: Any],
                              let label = dict["label"] as? String {
                        options.append(AskOption(label: label, description: dict["description"] as? String))
                    }
                }
            }

            let multiSelect = arguments["multi_select"] as? Bool ?? false
            let allowText = arguments["allow_text"] as? Bool ?? true
            let title = (arguments["title"] as? String)?.isEmpty == false ? (arguments["title"] as! String) : questionText
            let detail = arguments["detail"] as? String
            let timeoutSeconds = arguments["timeout_seconds"] as? Int

            let q = AskQuestion(header: nil, question: questionText, options: options, multiSelect: multiSelect, allowText: allowText)
            let req = AskRequest(
                kind: .question,
                title: title,
                detail: detail,
                questions: [q],
                source: AskSource(agent: "mcp", cwd: nil, session: nil),
                timeoutSeconds: timeoutSeconds
            )

            do {
                let response = try await askHandler(req)
                return serialize(formatAskUserResponse(id: id, response: response, timeoutSeconds: timeoutSeconds))
            } catch let clientError as AskClientError where clientError == .notRunning {
                return serialize(toolResult(id: id, isError: true, text: "AskIsland 没在运行，请直接在对话里问用户"))
            } catch {
                return serialize(toolResult(id: id, isError: true, text: error.localizedDescription))
            }

        case "request_user_action":
            guard let title = arguments["title"] as? String, !title.isEmpty,
                  let detail = arguments["detail"] as? String, !detail.isEmpty else {
                return serialize(toolResult(id: id, isError: true, text: "参数错误：title 和 detail 不能为空"))
            }

            let kindStr = arguments["kind"] as? String
            let actionKind = kindStr.flatMap { ActionKind(rawValue: $0) } ?? .other
            let timeoutSeconds = arguments["timeout_seconds"] as? Int

            let req = AskRequest(
                kind: .action,
                title: title,
                detail: detail,
                actionKind: actionKind,
                source: AskSource(agent: "mcp", cwd: nil, session: nil),
                timeoutSeconds: timeoutSeconds
            )

            do {
                let response = try await askHandler(req)
                return serialize(formatActionResponse(id: id, response: response, timeoutSeconds: timeoutSeconds))
            } catch let clientError as AskClientError where clientError == .notRunning {
                return serialize(toolResult(id: id, isError: true, text: "AskIsland 没在运行，请直接在对话里问用户"))
            } catch {
                return serialize(toolResult(id: id, isError: true, text: error.localizedDescription))
            }

        case "notify_user":
            guard let title = arguments["title"] as? String, !title.isEmpty else {
                return serialize(toolResult(id: id, isError: true, text: "参数错误：title 不能为空"))
            }
            let detail = arguments["detail"] as? String

            let req = AskRequest(
                kind: .notify,
                title: title,
                detail: detail,
                source: AskSource(agent: "mcp", cwd: nil, session: nil)
            )

            do {
                _ = try await askHandler(req)
                return serialize(toolResult(id: id, isError: false, text: "已通知"))
            } catch let clientError as AskClientError where clientError == .notRunning {
                return serialize(toolResult(id: id, isError: true, text: "AskIsland 没在运行，请直接在对话里问用户"))
            } catch {
                return serialize(toolResult(id: id, isError: true, text: error.localizedDescription))
            }

        default:
            return serialize(toolResult(id: id, isError: true, text: "未知工具: \(toolName)"))
        }
    }

    private func formatAskUserResponse(id: Any, response: AskResponse, timeoutSeconds: Int?) -> [String: Any] {
        switch response.status {
        case .answered:
            let display = response.answers.first?.display ?? ""
            return toolResult(id: id, isError: false, text: "用户回答：\(display)")
        case .declined:
            if let note = response.note, !note.isEmpty {
                return toolResult(id: id, isError: false, text: "用户拒绝回答：\(note)")
            } else {
                return toolResult(id: id, isError: false, text: "用户拒绝回答")
            }
        case .timeout:
            let s = timeoutSeconds ?? 0
            return toolResult(id: id, isError: false, text: "用户没有在 \(s) 秒内回答")
        case .dismissed:
            return toolResult(id: id, isError: false, text: "用户关闭了这个请求，没有回答")
        case .done:
            return toolResult(id: id, isError: false, text: "用户已完成")
        }
    }

    private func formatActionResponse(id: Any, response: AskResponse, timeoutSeconds: Int?) -> [String: Any] {
        switch response.status {
        case .done:
            if let note = response.note, !note.isEmpty {
                return toolResult(id: id, isError: false, text: "用户已完成，备注：\(note)")
            } else {
                return toolResult(id: id, isError: false, text: "用户已完成")
            }
        case .declined:
            if let note = response.note, !note.isEmpty {
                return toolResult(id: id, isError: false, text: "用户说做不了：\(note)")
            } else {
                return toolResult(id: id, isError: false, text: "用户说做不了")
            }
        case .timeout:
            let s = timeoutSeconds ?? 0
            return toolResult(id: id, isError: false, text: "用户没有在 \(s) 秒内回答")
        case .dismissed:
            return toolResult(id: id, isError: false, text: "用户关闭了这个请求，没有回答")
        case .answered:
            return toolResult(id: id, isError: false, text: "用户回答")
        }
    }

    private func toolResult(id: Any, isError: Bool, text: String) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ],
                "isError": isError
            ]
        ]
    }

    private func serialize(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Runs the server reading line-by-line from stdin and writing serialized responses to stdout.
    public func run(stdin: FileHandle = .standardInput, stdout: FileHandle = .standardOutput) async {
        let writer = MCPOutputWriter(handle: stdout)
        var buffer = Data()

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: 0..<newlineIndex)
                buffer.removeSubrange(0...newlineIndex)

                if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                    Task {
                        if let reply = await self.handle(line: line) {
                            await writer.write(reply)
                        }
                    }
                }
            }
        }
    }
}
