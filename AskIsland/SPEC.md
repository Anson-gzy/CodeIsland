# AskIsland spec

A notch island whose only job: when an agent needs the person (pick options, answer, do something on the
Mac / phone, type a password somewhere, log in), it shows up at the notch, says what to do, and the person
answers there. Agents reach it through an MCP server, a CLI, or Claude Code hooks. Shared types are in
`Sources/AskIslandCore/Models.swift` (AskRequest / AskResponse / AskEndpoint): use them, don't redefine.

## Core (Sources/AskIslandCore)

**Lenient decoding.** Clients send minimal JSON (curl, MCP). `AskRequest` decodes with defaults when keys are
missing: id "", questions [], createdAt now; `AskQuestion` options [], multiSelect false, allowText true;
`AskOption` may also decode from a bare string (label). Dates are ISO 8601 on both sides.

**AskStore** (`@MainActor`, `ObservableObject`) owns pending requests. The app UI only reads `pending` and calls
`resolve`; nothing else holds request state.
- `pending: [AskRequest]`, oldest first.
- `submit(_:) async -> AskResponse`: empty id → new UUID string; suspends until resolved. A second submit with
  an id already pending returns `.dismissed` at once and does not touch the first.
- `.notify`: appended to `pending`, returns `.dismissed` immediately; the store removes it after 15 s if
  nobody resolved it.
- `timeoutSeconds`: on expiry removed from `pending`, waiter gets `.timeout`.
- `resolve(_ id:, _ response:)`: removes and resumes the waiter; unknown id is a no-op; the response id is
  forced to the request id.
- `cancel(_ id:)`: removes without a response to anyone who cares (waiter gets `.dismissed`). The server calls it
  when the client's connection closes while waiting, so a question the agent abandoned (e.g. answered in the
  terminal instead) disappears from the island.

**AskServer**: HTTP/1.1 on 127.0.0.1 only (Network.framework), port 0 (random) unless `ASK_ISLAND_PORT`.
- `init(store:, endpointURL: URL = AskEndpoint.resolvedURL)`, `start() throws -> AskEndpoint`, `stop()`.
- On start writes the endpoint JSON (dir 0700, file 0600) with a random 32-hex token and its pid; `stop()`
  deletes the file only if it still holds this pid.
- `GET /health` → 200 `{"ok":true}` (no auth).
- `POST /ask`, header `Authorization: Bearer <token>`, body AskRequest JSON → holds the connection, replies
  200 with the AskResponse JSON when the store resolves. Wrong/missing token 401; undecodable body or
  `.question` with no questions or empty title 400 with `{"error": "..."}`; other paths 404. Body ≤ 1 MB.
- Client disconnect while waiting → `store.cancel(id)`.

**AskEndpoint.resolvedURL**: `ASK_ISLAND_ENDPOINT` env path if set, else `defaultURL`. Tests always use a temp path.

**AskClient**: `init(endpointURL: URL = AskEndpoint.resolvedURL)`; `ask(_:) async throws -> AskResponse`;
`isRunning() async -> Bool`. Throws `AskClientError.notRunning` when the endpoint file is missing, its pid is
dead, or the connection is refused. No request timeout of its own (a question may wait hours).

**ClaudeHook** (pure functions, no I/O): Claude Code hook stdin JSON → AskRequest?, and AskResponse → stdout JSON.
- `PermissionRequest` + tool `AskUserQuestion`: kind question, title "Claude 在问你", one AskQuestion per
  `tool_input.questions[]` (header, question, options label/description, multiSelect), allowText true;
  source agent "claude", cwd, session_id. Answered → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
  "decision":{"behavior":"allow","updatedInput":{...original tool_input, "questions": original questions,
  "answers": {<question text>: <AskAnswer.display>}}}}}`. Duplicate question texts get keys "text_2", "text_3".
  Declined / timeout / dismissed → `"decision":{"behavior":"deny","message":"用户没有在 AskIsland 回答"}` (append
  the note when there is one).
- `PermissionRequest` + any other tool: question, title "Claude 想用 <tool>", detail = `command` for Bash,
  `file_path` for Write/Edit/MultiEdit/NotebookEdit, else compact JSON of tool_input cut to 500 chars;
  one question "允许吗？" with options 允许 / 拒绝, allowText false. 允许 → behavior allow; anything else → deny.
- `Notification`: `notification_type == "permission_prompt"` → nil (the PermissionRequest covers it);
  otherwise notify, title = `message`, source as above.
- Anything else → nil.

**MCPServer** (pure handler, injectable `ask: (AskRequest) async throws -> AskResponse`): JSON-RPC 2.0,
newline-delimited on stdio. `initialize` (echo the client's protocolVersion, else "2025-06-18"; capabilities
`{"tools":{}}`; serverInfo `ask-island` 0.1.0), `notifications/*` no reply, `ping`, `tools/list`, `tools/call`;
unknown method → error -32601. Calls run concurrently (a waiting question must not block `ping`); stdout writes
are serialized. Tools (descriptions in Chinese, they are how agents learn when to use it):
- `ask_user` {question*, options: [string | {label, description}], multi_select, allow_text (default true),
  title, detail, timeout_seconds}: "需要用户做选择或回答问题时用（比在对话里问更显眼，用户不在终端前也能看到）".
  Result text: `用户回答：<display>`; declined `用户拒绝回答：<note>`; timeout `用户没有在 <n> 秒内回答`.
- `request_user_action` {title*, detail* (要用户做什么，写成步骤), kind: computer|phone|password|login|other,
  timeout_seconds}: "需要用户亲手操作电脑/手机、输入密码、登录、插线、点确认时用；会等到用户勾选已完成。不要让用户把
  密码告诉你". Result `用户已完成` (+ `，备注：<note>`) / `用户说做不了：<note>` / timeout text.
- `notify_user` {title*, detail}: "只通知、不需要回答时用（任务完成、需要用户回来看一眼）". Result `已通知`.
- App not running → `isError: true`, text `AskIsland 没在运行，请直接在对话里问用户`.

## CLI (Sources/ask-island/main.swift)

```
ask-island ask "<question>" [-o "<label>[::<description>]"]... [--multi] [--no-text] [--title T]
           [--detail D] [--header H] [--timeout S] [--agent A] [--json]
ask-island do "<title>" [--detail D] [--kind computer|phone|password|login|other] [--timeout S] [--agent A] [--json]
ask-island notify "<title>" [--detail D] [--agent A]
ask-island hook      # Claude Code hook: stdin JSON → stdout JSON (ClaudeHook)
ask-island mcp       # stdio MCP server (MCPServer)
```
- `ask` title defaults to the question; prints `AskAnswer.display`. `do` prints the note if any.
- Exit: 0 answered/done/notified, 3 declined (note on stderr), 4 timeout, 5 dismissed, 2 app not running
  (stderr `AskIsland 没在运行`), 64 usage error. `--json` prints the AskResponse JSON instead.
- source: cwd = current dir; agent = --agent, else env `ASK_ISLAND_AGENT`, else "claude" if `CLAUDECODE=1`,
  "codex" if any `CODEX_` env var, else "cli".
- `hook`: app not running or the event maps to nil → print nothing, exit 0 (Claude falls back to its own UI).
  Never exit non-zero.

## App (Sources/AskIsland)

Agent app (`NSApp.setActivationPolicy(.accessory)`, no Dock icon). At launch: one `AskStore`, one `AskServer`
started on it, the island window, a status item. Reuse, by copying into this target (the old app is not a
dependency): notch geometry from `../Sources/CodeIsland/ScreenDetector.swift`; `NotchPanelShape`,
`IslandBackground` and `ClearLensGlass` (NSGlassEffectView, private `_variant` 11, black fade in its contentView)
from `../Sources/CodeIsland/NotchPanelView.swift`; the panel setup in `showPanel()` of
`../Sources/CodeIsland/PanelWindowController.swift` (borderless nonactivating `KeyablePanel`, level mainMenu+2,
clear background, all spaces + full-screen auxiliary). Screen: the one with a notch, else the main screen.

**States**
- Nothing pending: nothing visible; the window ignores mouse events so the menu bar works underneath.
- Pending, expanded (default when something arrives): island hangs from the notch, 480 pt wide, height fits the
  card up to 70% of the screen (card scrolls beyond), expanded glass background like CodeIsland. Shows the oldest
  pending request. Header: agent name (`source.agent`, else "Agent") · last path component of `source.cwd` ·
  "1/3" when more than one, and a chevron that collapses.
- Pending, collapsed: a black pill the notch's width plus small wings, showing an orange count badge; click
  expands. A new arrival while collapsed keeps it collapsed and pulses the badge once.
- Each new arrival plays `NSSound(named: "Glass")` once. Arrival never steals focus.

**Question card**: title (bold), detail (secondary, selectable), then per question: header chip, question text,
option rows (label, small description). Single-select = radio (picking replaces), multi = checkboxes. A text field
when `allowText` (placeholder "其他（可选）", or "输入回答" when there are no options). "提交" is enabled when
every question has a selection or non-empty text → `.answered` with one AskAnswer per question (selected labels
in option order, trimmed text or nil). "拒绝回答" → `.declined`. Keys when no text field has focus: 1–9 toggle
options of the first question still unanswered, Return submits, Esc collapses.

**Action card**: SF Symbol per actionKind (computer `desktopcomputer`, phone `iphone`, password `key.fill`,
login `person.badge.key`, other/nil `hand.raised`), title, detail (steps, selectable), note field "备注（可选）",
primary "我已完成" → `.done` with note, secondary "做不了" → `.declined` with note. Password kind adds the line
"密码请在它提示的地方输入，不要发给 agent". No password field anywhere in the app.

**Notify card**: title, detail, "知道了" → `.dismissed`. (Store drops it after 15 s anyway.)

**Focus**: text fields must take typing including Chinese IME: clicking makes the panel key and focusing a
text field activates the app. After a resolve leaves nothing pending, reactivate the app that was frontmost
before.

**Status item** (`bubble.left.and.exclamationmark.bubble.right`): "测试：提问", "测试：让我操作", "退出".
The test items submit sample requests straight into the store. If the server failed to start, the item shows a
warning symbol and the menu says why.

**`--demo`** launch argument: submits a two-question request (one single, one multi-select with descriptions),
then a phone action, then a notify, so screenshots show every card.
