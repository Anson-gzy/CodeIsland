import XCTest
import Network
@testable import AskIslandCore

final class CoreTests: XCTestCase {
    private func createTempEndpointURL() -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskIslandTests-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("endpoint.json")
        return (dir, file)
    }

    // MARK: - Server Lifecycle & Health

    func testServerStartStopAndHealth() async throws {
        let (tempDir, endpointURL) = createTempEndpointURL()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = await AskStore()
        let server = AskServer(store: store, endpointURL: endpointURL)
        let endpoint = try server.start()
        defer {
            server.stop()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: endpointURL.path))
        XCTAssertEqual(endpoint.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(endpoint.token.count, 32)

        let client = AskClient(endpointURL: endpointURL)
        let running = await client.isRunning()
        XCTAssertTrue(running)

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpointURL.path))
        let runningAfterStop = await client.isRunning()
        XCTAssertFalse(runningAfterStop)
    }

    // MARK: - A2: End-to-End Test

    func testEndToEndQuestionAnswered() async throws {
        let (tempDir, endpointURL) = createTempEndpointURL()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = await AskStore()
        let server = AskServer(store: store, endpointURL: endpointURL)
        _ = try server.start()
        defer {
            server.stop()
        }

        let client = AskClient(endpointURL: endpointURL)
        let req = AskRequest(
            kind: .question,
            title: "Choose deployment",
            questions: [
                AskQuestion(
                    question: "Pick target",
                    options: [AskOption(label: "Staging"), AskOption(label: "Production")]
                )
            ]
        )

        let task = Task {
            try await client.ask(req)
        }

        var pendingReq: AskRequest?
        for _ in 0..<100 {
            let pending = await store.pending
            if let first = pending.first {
                pendingReq = first
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        guard let pending = pendingReq else {
            XCTFail("Request did not appear in pending")
            return
        }

        XCTAssertEqual(pending.title, "Choose deployment")

        let answer = AskAnswer(selected: ["Staging"])
        let resolveResponse = AskResponse(id: pending.id, status: .answered, answers: [answer])
        await store.resolve(pending.id, resolveResponse)

        let clientResponse = try await task.value
        XCTAssertEqual(clientResponse.status, .answered)
        XCTAssertEqual(clientResponse.id, pending.id)
        XCTAssertEqual(clientResponse.answers.first?.selected, ["Staging"])
        XCTAssertEqual(clientResponse.answers.first?.display, "Staging")

        let remainingPending = await store.pending
        XCTAssertTrue(remainingPending.isEmpty)
    }

    // MARK: - A3: Client Disconnect / Cancellation

    func testClientTaskCancelledRemovesPending() async throws {
        let (tempDir, endpointURL) = createTempEndpointURL()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = await AskStore()
        let server = AskServer(store: store, endpointURL: endpointURL)
        _ = try server.start()
        defer {
            server.stop()
        }

        let client = AskClient(endpointURL: endpointURL)
        let req = AskRequest(
            kind: .question,
            title: "Question to cancel",
            questions: [AskQuestion(question: "Will be cancelled?")]
        )

        let task = Task {
            try await client.ask(req)
        }

        var appeared = false
        for _ in 0..<100 {
            let count = await store.pending.count
            if count == 1 {
                appeared = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(appeared, "Request must appear in store.pending")

        task.cancel()

        var removed = false
        for _ in 0..<100 {
            let count = await store.pending.count
            if count == 0 {
                removed = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(removed, "Cancelled client task must remove request from store.pending")
    }

    func testConnectionClosedWhileWaitingRemovesPending() async throws {
        let (tempDir, endpointURL) = createTempEndpointURL()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = await AskStore()
        let server = AskServer(store: store, endpointURL: endpointURL)
        let ep = try server.start()
        defer {
            server.stop()
        }

        let req = AskRequest(
            kind: .question,
            title: "Direct connection close",
            questions: [AskQuestion(question: "Will close?")]
        )
        let reqData = try JSONEncoder().encode(req)
        let httpMessage = "POST /ask HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(ep.token)\r\nContent-Type: application/json\r\nContent-Length: \(reqData.count)\r\nConnection: close\r\n\r\n"
        var fullPayload = httpMessage.data(using: .utf8)!
        fullPayload.append(reqData)

        let queue = DispatchQueue(label: "test.nwconnection")
        let nwConn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: ep.port)!,
            using: .tcp
        )

        let readyExpectation = expectation(description: "NWConnection ready")
        nwConn.stateUpdateHandler = { state in
            if case .ready = state {
                readyExpectation.fulfill()
            }
        }
        nwConn.start(queue: queue)
        await fulfillment(of: [readyExpectation], timeout: 2.0)

        nwConn.send(content: fullPayload, completion: .contentProcessed { _ in })

        var appeared = false
        for _ in 0..<100 {
            let count = await store.pending.count
            if count == 1 {
                appeared = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(appeared, "Request must appear in store.pending")

        // Close connection from client side
        nwConn.cancel()

        var removed = false
        for _ in 0..<100 {
            let count = await store.pending.count
            if count == 0 {
                removed = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(removed, "Closed TCP connection must remove request from store.pending")
    }

    // MARK: - A4: Timeout, Notify, Duplicate ID

    func testTimeoutYieldsTimeoutResponse() async throws {
        let (tempDir, endpointURL) = createTempEndpointURL()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = await AskStore()
        let server = AskServer(store: store, endpointURL: endpointURL)
        _ = try server.start()
        defer {
            server.stop()
        }

        let client = AskClient(endpointURL: endpointURL)
        let req = AskRequest(
            kind: .question,
            title: "Will timeout",
            questions: [AskQuestion(question: "Q1")],
            timeoutSeconds: 1
        )

        let response = try await client.ask(req)
        XCTAssertEqual(response.status, .timeout)

        let pending = await store.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func testNotifyReturnsDismissedImmediately() async throws {
        let store = await AskStore()
        let req = AskRequest(
            kind: .notify,
            title: "Task completed",
            detail: "All done"
        )

        let response = await store.submit(req)
        XCTAssertEqual(response.status, .dismissed)

        let pending = await store.pending
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Task completed")
    }

    func testDuplicatePendingIDReturnsDismissedImmediately() async throws {
        let store = await AskStore()
        let req1 = AskRequest(
            id: "unique-test-id",
            kind: .question,
            title: "First question",
            questions: [AskQuestion(question: "Q1")]
        )
        let req2 = AskRequest(
            id: "unique-test-id",
            kind: .question,
            title: "Second question duplicate",
            questions: [AskQuestion(question: "Q2")]
        )

        let task1 = Task {
            await store.submit(req1)
        }

        for _ in 0..<50 {
            if await store.pending.count == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let res2 = await store.submit(req2)
        XCTAssertEqual(res2.status, .dismissed)
        XCTAssertEqual(res2.id, "unique-test-id")

        // First request is still pending and untouched
        let pending = await store.pending
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "First question")

        await store.resolve("unique-test-id", AskResponse(id: "unique-test-id", status: .answered))
        let res1 = await task1.value
        XCTAssertEqual(res1.status, .answered)
    }

    // MARK: - A5: Auth 401 & Validation 400

    func testPostAskWithoutTokenIs401() async throws {
        let (tempDir, endpointURL) = createTempEndpointURL()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = await AskStore()
        let server = AskServer(store: store, endpointURL: endpointURL)
        let ep = try server.start()
        defer {
            server.stop()
        }

        let url = URL(string: "http://127.0.0.1:\(ep.port)/ask")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let req = AskRequest(kind: .question, title: "Test", questions: [AskQuestion(question: "Q")])
        request.httpBody = try JSONEncoder().encode(req)

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 401)
    }

    func testPostAskWithEmptyQuestionsIs400() async throws {
        let (tempDir, endpointURL) = createTempEndpointURL()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = await AskStore()
        let server = AskServer(store: store, endpointURL: endpointURL)
        let ep = try server.start()
        defer {
            server.stop()
        }

        let url = URL(string: "http://127.0.0.1:\(ep.port)/ask")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ep.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let emptyQuestionsJSON = #"{"kind": "question", "title": "Test Title", "questions": []}"#
        request.httpBody = emptyQuestionsJSON.data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 400)
    }

    func testPostAskWithEmptyTitleIs400() async throws {
        let (tempDir, endpointURL) = createTempEndpointURL()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = await AskStore()
        let server = AskServer(store: store, endpointURL: endpointURL)
        let ep = try server.start()
        defer {
            server.stop()
        }

        let url = URL(string: "http://127.0.0.1:\(ep.port)/ask")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ep.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let emptyTitleJSON = #"{"kind": "question", "title": "  ", "questions": [{"question": "Q"}]}"#
        request.httpBody = emptyTitleJSON.data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 400)
    }

    func testServer404OnUnknownPath() async throws {
        let (tempDir, endpointURL) = createTempEndpointURL()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = await AskStore()
        let server = AskServer(store: store, endpointURL: endpointURL)
        let ep = try server.start()
        defer {
            server.stop()
        }

        let url = URL(string: "http://127.0.0.1:\(ep.port)/unknown")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 404)
    }

    // MARK: - A6: ClaudeHook Coverage

    func testClaudeHookAskUserQuestionTwoQuestionsKeepsQuestionsAndKeysAnswers() throws {
        let inputJSON = """
        {
          "hook_event_name": "PermissionRequest",
          "tool_name": "AskUserQuestion",
          "tool_input": {
            "questions": [
              {
                "question": "Which deployment target?",
                "options": [{"label": "Staging"}, {"label": "Production"}],
                "multiSelect": false
              },
              {
                "question": "Which components to deploy?",
                "options": [{"label": "API"}, {"label": "Web"}, {"label": "Worker"}],
                "multiSelect": true
              }
            ]
          }
        }
        """

        guard let parsed = ClaudeHook.parseRequest(from: inputJSON) else {
            XCTFail("ClaudeHook failed to parse AskUserQuestion")
            return
        }

        XCTAssertEqual(parsed.request.kind, .question)
        XCTAssertEqual(parsed.request.title, "Claude has a question")
        XCTAssertEqual(parsed.request.questions.count, 2)
        XCTAssertFalse(parsed.request.questions[0].multiSelect)
        XCTAssertTrue(parsed.request.questions[1].multiSelect)

        let response = AskResponse(
            id: parsed.request.id,
            status: .answered,
            answers: [
                AskAnswer(selected: ["Staging"]),
                AskAnswer(selected: ["API", "Web"])
            ]
        )

        guard let formatted = ClaudeHook.formatResponse(request: parsed.request, response: response, rawInput: parsed.rawInput),
              let data = formatted.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookSpecific = dict["hookSpecificOutput"] as? [String: Any],
              let decision = hookSpecific["decision"] as? [String: Any] else {
            XCTFail("Failed to deserialize formatted response")
            return
        }

        XCTAssertEqual(hookSpecific["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual(decision["behavior"] as? String, "allow")

        guard let updatedInput = decision["updatedInput"] as? [String: Any] else {
            XCTFail("Missing updatedInput")
            return
        }

        // Keeps questions
        guard let originalQuestions = updatedInput["questions"] as? [[String: Any]] else {
            XCTFail("questions key missing in updatedInput")
            return
        }
        XCTAssertEqual(originalQuestions.count, 2)

        // Answers keyed by question text with display values
        guard let answers = updatedInput["answers"] as? [String: String] else {
            XCTFail("answers key missing in updatedInput")
            return
        }
        XCTAssertEqual(answers["Which deployment target?"], "Staging")
        XCTAssertEqual(answers["Which components to deploy?"], "API, Web")
    }

    func testClaudeHookAskUserQuestionDeclinedProducesBehaviorDeny() throws {
        let inputJSON = """
        {
          "hook_event_name": "PermissionRequest",
          "tool_name": "AskUserQuestion",
          "tool_input": {
            "questions": [
              {
                "question": "Proceed with migration?"
              }
            ]
          }
        }
        """

        guard let parsed = ClaudeHook.parseRequest(from: inputJSON) else {
            XCTFail("ClaudeHook failed to parse request")
            return
        }

        let declinedResponse = AskResponse(
            id: parsed.request.id,
            status: .declined,
            note: "User cancelled"
        )

        guard let formatted = ClaudeHook.formatResponse(request: parsed.request, response: declinedResponse, rawInput: parsed.rawInput),
              let data = formatted.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookSpecific = dict["hookSpecificOutput"] as? [String: Any],
              let decision = hookSpecific["decision"] as? [String: Any] else {
            XCTFail("Failed to deserialize formatted response")
            return
        }

        XCTAssertEqual(decision["behavior"] as? String, "deny")
        let message = decision["message"] as? String ?? ""
        XCTAssertTrue(message.contains("The user did not answer in AskIsland"))
        XCTAssertTrue(message.contains("User cancelled"))
    }

    func testClaudeHookBashPermissionRequestMapsAllowToAllowAndDenyToDeny() throws {
        let inputJSON = """
        {
          "hook_event_name": "PermissionRequest",
          "tool_name": "Bash",
          "tool_input": {
            "command": "rm -rf /tmp/build"
          }
        }
        """

        guard let parsed = ClaudeHook.parseRequest(from: inputJSON) else {
            XCTFail("ClaudeHook failed to parse Bash request")
            return
        }

        XCTAssertEqual(parsed.request.title, "Claude wants to use Bash")
        XCTAssertEqual(parsed.request.detail, "rm -rf /tmp/build")
        XCTAssertEqual(parsed.request.questions.first?.options.map(\.label), ["Allow", "Deny"])

        // 允许 -> allow
        let allowResponse = AskResponse(
            id: parsed.request.id,
            status: .answered,
            answers: [AskAnswer(selected: ["Allow"])]
        )
        guard let formattedAllow = ClaudeHook.formatResponse(request: parsed.request, response: allowResponse, rawInput: parsed.rawInput),
              let dataAllow = formattedAllow.data(using: .utf8),
              let dictAllow = try? JSONSerialization.jsonObject(with: dataAllow) as? [String: Any],
              let decisionAllow = (dictAllow["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any] else {
            XCTFail("Failed to parse allow response")
            return
        }
        XCTAssertEqual(decisionAllow["behavior"] as? String, "allow")

        // 拒绝 -> deny
        let denyResponse = AskResponse(
            id: parsed.request.id,
            status: .answered,
            answers: [AskAnswer(selected: ["Deny"])]
        )
        guard let formattedDeny = ClaudeHook.formatResponse(request: parsed.request, response: denyResponse, rawInput: parsed.rawInput),
              let dataDeny = formattedDeny.data(using: .utf8),
              let dictDeny = try? JSONSerialization.jsonObject(with: dataDeny) as? [String: Any],
              let decisionDeny = (dictDeny["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any] else {
            XCTFail("Failed to parse deny response")
            return
        }
        XCTAssertEqual(decisionDeny["behavior"] as? String, "deny")
    }

    func testClaudeHookNotificationPermissionPromptMapsToNil() throws {
        let promptJSON = """
        {
          "hook_event_name": "Notification",
          "notification_type": "permission_prompt",
          "message": "Needs permission"
        }
        """
        XCTAssertNil(ClaudeHook.parseRequest(from: promptJSON))

        let otherNotificationJSON = """
        {
          "hook_event_name": "Notification",
          "notification_type": "info",
          "message": "Build finished successfully"
        }
        """
        guard let parsed = ClaudeHook.parseRequest(from: otherNotificationJSON) else {
            XCTFail("Failed to parse info notification")
            return
        }
        XCTAssertEqual(parsed.request.kind, .notify)
        XCTAssertEqual(parsed.request.title, "Build finished successfully")
    }

    // MARK: - Lenient Decoding & Models

    func testLenientDecodingOfAskRequestAndOptions() throws {
        let minimalJSON = """
        {
          "kind": "question",
          "title": "Minimal Question",
          "questions": [
            {
              "question": "Pick color",
              "options": ["Red", "Green", "Blue"]
            }
          ]
        }
        """.data(using: .utf8)!

        let req = try JSONDecoder().decode(AskRequest.self, from: minimalJSON)
        XCTAssertEqual(req.id, "")
        XCTAssertEqual(req.title, "Minimal Question")
        XCTAssertEqual(req.questions.count, 1)
        XCTAssertEqual(req.questions[0].options.map(\.label), ["Red", "Green", "Blue"])
        XCTAssertFalse(req.questions[0].multiSelect)
        XCTAssertTrue(req.questions[0].allowText)
    }

    func testClaudeHookDuplicateQuestionTextsKeyWithSuffixes() throws {
        let inputJSON = """
        {
          "hook_event_name": "PermissionRequest",
          "tool_name": "AskUserQuestion",
          "tool_input": {
            "questions": [
              { "question": "Are you sure?" },
              { "question": "Are you sure?" }
            ]
          }
        }
        """

        guard let parsed = ClaudeHook.parseRequest(from: inputJSON) else {
            XCTFail("Failed to parse duplicate questions")
            return
        }

        let response = AskResponse(
            id: parsed.request.id,
            status: .answered,
            answers: [
                AskAnswer(text: "Yes"),
                AskAnswer(text: "Positive")
            ]
        )

        guard let formatted = ClaudeHook.formatResponse(request: parsed.request, response: response, rawInput: parsed.rawInput),
              let dict = (try? JSONSerialization.jsonObject(with: formatted.data(using: .utf8)!)) as? [String: Any],
              let answers = ((dict["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["updatedInput"] as? [String: Any],
              let answersDict = answers["answers"] as? [String: String] else {
            XCTFail("Failed to extract answers")
            return
        }

        XCTAssertEqual(answersDict["Are you sure?"], "Yes")
        XCTAssertEqual(answersDict["Are you sure?_2"], "Positive")
    }
}
