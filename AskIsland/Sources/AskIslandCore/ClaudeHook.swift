import Foundation

/// Pure functions for Claude Code hook stdin JSON → AskRequest?, and AskResponse → stdout JSON.
public enum ClaudeHook {
    /// Parses Claude Code hook stdin JSON into an `AskRequest` and the raw input dictionary.
    public static func parseRequest(from inputData: Data) -> (request: AskRequest, rawInput: [String: Any])? {
        guard let dict = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else {
            return nil
        }
        return parseRequest(from: dict)
    }

    /// Parses Claude Code hook stdin JSON string into an `AskRequest` and the raw input dictionary.
    public static func parseRequest(from jsonString: String) -> (request: AskRequest, rawInput: [String: Any])? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return parseRequest(from: data)
    }

    /// Parses Claude Code hook dictionary into an `AskRequest` and the raw input dictionary.
    public static func parseRequest(from dict: [String: Any]) -> (request: AskRequest, rawInput: [String: Any])? {
        let eventName = (dict["hook_event_name"] as? String) ?? (dict["hookEventName"] as? String)
        guard let eventName = eventName else { return nil }

        let cwd = dict["cwd"] as? String
        let sessionId = (dict["session_id"] as? String) ?? (dict["sessionId"] as? String)
        let source = AskSource(agent: "claude", cwd: cwd, session: sessionId)

        if eventName == "PermissionRequest" {
            let toolName = (dict["tool_name"] as? String) ?? (dict["toolName"] as? String) ?? ""
            let toolInput = ((dict["tool_input"] as? [String: Any]) ?? (dict["toolInput"] as? [String: Any])) ?? [:]

            if toolName == "AskUserQuestion" {
                var questions: [AskQuestion] = []
                let rawQuestions = (toolInput["questions"] as? [Any]) ?? []

                for rawQ in rawQuestions {
                    if let qDict = rawQ as? [String: Any] {
                        let header = qDict["header"] as? String
                        let questionText = (qDict["question"] as? String) ?? ""
                        var options: [AskOption] = []
                        if let rawOpts = qDict["options"] as? [Any] {
                            for rawOpt in rawOpts {
                                if let optStr = rawOpt as? String {
                                    options.append(AskOption(label: optStr))
                                } else if let optDict = rawOpt as? [String: Any],
                                          let label = optDict["label"] as? String {
                                    options.append(AskOption(label: label, description: optDict["description"] as? String))
                                }
                            }
                        }
                        let multiSelect = (qDict["multiSelect"] as? Bool) ?? (qDict["multi_select"] as? Bool) ?? false
                        questions.append(AskQuestion(header: header, question: questionText, options: options, multiSelect: multiSelect, allowText: true))
                    }
                }

                let req = AskRequest(
                    kind: .question,
                    title: "Claude has a question",
                    questions: questions,
                    source: source
                )
                return (req, dict)
            } else {
                // Any other tool
                let title = "Claude wants to use \(toolName)"
                let detail: String?
                let lowerTool = toolName.lowercased()

                if lowerTool == "bash" {
                    detail = toolInput["command"] as? String
                } else if ["write", "edit", "multiedit", "notebookedit"].contains(lowerTool) {
                    detail = (toolInput["file_path"] as? String) ?? (toolInput["filePath"] as? String)
                } else {
                    if let data = try? JSONSerialization.data(withJSONObject: toolInput, options: []),
                       let jsonStr = String(data: data, encoding: .utf8) {
                        detail = String(jsonStr.prefix(500))
                    } else {
                        detail = nil
                    }
                }

                let question = AskQuestion(
                    question: "Allow this?",
                    options: [AskOption(label: "Allow"), AskOption(label: "Deny")],
                    multiSelect: false,
                    allowText: false
                )
                let req = AskRequest(
                    kind: .question,
                    title: title,
                    detail: detail,
                    questions: [question],
                    source: source
                )
                return (req, dict)
            }
        } else if eventName == "Notification" {
            let notificationType = (dict["notification_type"] as? String) ?? (dict["notificationType"] as? String)
            if notificationType == "permission_prompt" {
                return nil
            }
            let message = (dict["message"] as? String) ?? ""
            let req = AskRequest(
                kind: .notify,
                title: message,
                source: source
            )
            return (req, dict)
        }

        return nil
    }

    /// Formats the stdout JSON string given the AskRequest, AskResponse, and raw input dict.
    public static func formatResponse(request: AskRequest, response: AskResponse, rawInput: [String: Any]) -> String? {
        let eventName = (rawInput["hook_event_name"] as? String) ?? (rawInput["hookEventName"] as? String)
        guard eventName == "PermissionRequest" else {
            return nil
        }

        let toolName = (rawInput["tool_name"] as? String) ?? (rawInput["toolName"] as? String) ?? ""

        if toolName == "AskUserQuestion" {
            if response.status == .answered {
                var answersDict: [String: String] = [:]
                var counts: [String: Int] = [:]

                for (idx, q) in request.questions.enumerated() {
                    let text = q.question
                    let count = counts[text, default: 0] + 1
                    counts[text] = count
                    let key = count == 1 ? text : "\(text)_\(count)"
                    let display = idx < response.answers.count ? response.answers[idx].display : ""
                    answersDict[key] = display
                }

                var updatedInput = ((rawInput["tool_input"] as? [String: Any]) ?? (rawInput["toolInput"] as? [String: Any])) ?? [:]
                updatedInput["answers"] = answersDict

                let output: [String: Any] = [
                    "hookSpecificOutput": [
                        "hookEventName": "PermissionRequest",
                        "decision": [
                            "behavior": "allow",
                            "updatedInput": updatedInput
                        ]
                    ]
                ]
                return serialize(output)
            } else {
                let note = response.note
                let message: String
                if let note = note, !note.isEmpty {
                    message = "The user did not answer in AskIsland: \(note)"
                } else {
                    message = "The user did not answer in AskIsland"
                }

                let output: [String: Any] = [
                    "hookSpecificOutput": [
                        "hookEventName": "PermissionRequest",
                        "decision": [
                            "behavior": "deny",
                            "message": message
                        ]
                    ]
                ]
                return serialize(output)
            }
        } else {
            // Any other tool
            let isAllowed = response.status == .answered &&
                (response.answers.first?.selected.contains("Allow") == true)

            if isAllowed {
                let output: [String: Any] = [
                    "hookSpecificOutput": [
                        "hookEventName": "PermissionRequest",
                        "decision": [
                            "behavior": "allow"
                        ]
                    ]
                ]
                return serialize(output)
            } else {
                let note = response.note
                let message: String
                if let note = note, !note.isEmpty {
                    message = "The user did not allow it in AskIsland: \(note)"
                } else {
                    message = "The user did not allow it in AskIsland"
                }

                let output: [String: Any] = [
                    "hookSpecificOutput": [
                        "hookEventName": "PermissionRequest",
                        "decision": [
                            "behavior": "deny",
                            "message": message
                        ]
                    ]
                ]
                return serialize(output)
            }
        }
    }

    private static func serialize(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
