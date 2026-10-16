# AskIsland spec

A notch island whose only job: when an agent needs the person (pick options, answer, do something on the
Mac / phone, type a password somewhere, log in), it shows up at the notch, says what to do, and the person
answers there. Agents reach it through the `ask-island` CLI (one line in AGENTS.md); Claude Code's own AskUserQuestion reaches it through a hook. Shared types are in
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
- `PermissionRequest` + tool `AskUserQuestion`: kind question, title "Claude has a question", one AskQuestion per
  `tool_input.questions[]` (header, question, options label/description, multiSelect), allowText true;
  source agent "claude", cwd, session_id. Answered → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
  "decision":{"behavior":"allow","updatedInput":{...original tool_input, "questions": original questions,
  "answers": {<question text>: <AskAnswer.display>}}}}}`. Duplicate question texts get keys "text_2", "text_3".
  Declined / timeout / dismissed → `"decision":{"behavior":"deny","message":"The user did not answer in AskIsland"}` (append
  the note when there is one).
- `PermissionRequest` + any other tool: question, title "Claude wants to use <tool>", detail = `command` for Bash,
  `file_path` for Write/Edit/MultiEdit/NotebookEdit, else compact JSON of tool_input cut to 500 chars;
  one question "Allow this?" with options Allow / Deny, allowText false. Allow → behavior allow; anything else → deny.
- `Notification`: `notification_type == "permission_prompt"` → nil (the PermissionRequest covers it);
  otherwise notify, title = `message`, source as above.
- Anything else → nil.

## CLI (Sources/ask-island/main.swift)

```
ask-island ask "<question>" [-o "<label>[::<description>]"]... [--multi] [--no-text] [--title T]
           [--detail D] [--header H] [--timeout S] [--agent A] [--json]
ask-island do "<title>" [--detail D] [--kind computer|phone|password|login|other] [--timeout S] [--agent A] [--json]
ask-island notify "<title>" [--detail D] [--agent A]
ask-island hook      # Claude Code hook: stdin JSON → stdout JSON (ClaudeHook)
```
- `ask` title defaults to the question; prints `AskAnswer.display`. `do` prints the note if any.
- Exit: 0 answered/done/notified, 3 declined (note on stderr), 4 timeout, 5 dismissed, 2 app not running
  (stderr `AskIsland is not running`), 64 usage error. `--json` prints the AskResponse JSON instead.
- source: cwd = current dir; agent = --agent, else env `ASK_ISLAND_AGENT`, else "claude" if `CLAUDECODE=1`,
  "codex" if any `CODEX_` env var, else "cli".
- `hook`: app not running or the event maps to nil → print nothing, exit 0 (Claude falls back to its own UI).
  Never exit non-zero.

## App (Sources/AskIsland)

Agent app (`NSApp.setActivationPolicy(.accessory)`, no Dock icon). At launch: one `AskStore`, one `AskServer`
started on it, the island window, a status item. Notch geometry (`ScreenDetector`), `NotchPanelShape`,
`IslandBackground`, `ClearLensGlass` and the borderless nonactivating `KeyablePanel` (level mainMenu+2, clear
background, all spaces + full-screen auxiliary) came from upstream CodeIsland and now live in this target only.
Screen: the one with a notch, else the main screen.

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
when `allowText` (placeholder "Other (optional)", or "Type your answer" when there are no options). "Submit" is enabled when
every question has a selection or non-empty text → `.answered` with one AskAnswer per question (selected labels
in option order, trimmed text or nil). "Decline" → `.declined`. Keys when no text field has focus: 1–9 toggle
options of the first question still unanswered, Return submits, Esc collapses.

**Action card**: SF Symbol per actionKind (computer `desktopcomputer`, phone `iphone`, password `key.fill`,
login `person.badge.key`, other/nil `hand.raised`), title, detail (steps, selectable), note field "Note (optional)",
primary "Done" → `.done` with note, secondary "Can't do it" → `.declined` with note. Password kind adds the line
"Type the password where it asks for it. Never send it to the agent.". No password field anywhere in the app.

**Notify card**: title, detail, "Got it" → `.dismissed`. (Store drops it after 15 s anyway.)

**Focus**: text fields must take typing including Chinese IME: clicking makes the panel key and focusing a
text field activates the app. After a resolve leaves nothing pending, reactivate the app that was frontmost
before.

**Status item** (`bubble.left.and.exclamationmark.bubble.right`): "Test: Ask a Question", "Test: Request an Action", "Quit".
The test items submit sample requests straight into the store. If the server failed to start, the item shows a
warning symbol and the menu says why.

**`--demo`** launch argument: submits a two-question request (one single, one multi-select with descriptions),
then a phone action, then a notify, so screenshots show every card.

## Expand / collapse animation (like upstream CodeIsland)

The island grows out of the notch and shrinks back into it; the window never resizes to animate.
- The panel window has a fixed frame: centered under the notch, width 560, height 70% of the screen, top
  edge at the screen top. Fully transparent pixels of the non-opaque borderless panel let clicks through (that
  is how upstream does it; no hit-test override needed). `ignoresMouseEvents` stays true while nothing is
  pending.
- One island view, top-anchored, horizontally centered, whose frame and shape animate between three sizes:
  hidden = the hardware notch (notchWidth × notchHeight, plain black: invisible against the notch);
  collapsed = notchWidth + 24 × notchHeight + 26 (black pill, badge below the notch);
  expanded = 480 × measured content height (clamped to the window).
  `NotchPanelShape` topExtension / bottomRadius animate with it (hidden 3/8, collapsed 3/12, expanded 14/24).
- Expanded background = the existing glass (`IslandBackground` with `ClearLensGlass`); other states plain black.
  The glass fades in with the expansion (opacity transition), not popping.
- Card content and the collapsed badge use upstream's transition: blur 5 + opacity, combined with
  `.scale(0.96, anchor: .top)`; switching from one request to the next uses the same transition.
- Curves (copy upstream `NotchAnimation`): open = spring(response 0.42, damping 0.82); close =
  spring(response 0.38, damping 1.0) (critically damped so the shape never overshoots above the notch).
  Expanding uses open, collapsing/hiding uses close.
- First arrival: hidden → expanded (grows from the notch). Resolving the last request: expanded → hidden,
  then `ignoresMouseEvents = true` after the close animation ends.

## Visual style (reference: a Liquid Glass "New Message" compose sheet)

The whole island is one capsule of clear lens glass hanging from the notch (iOS Spotlight / "Search or Ask"
look), styled like a macOS 26 compose sheet. All UI text is English.

**Capsule**
- `ClearLensGlass` (`_variant` 11), all four corners round, top edge on the screen's top edge, corner radius
  `min(64, height/2)`: on this glass the refracting rim is as wide as the corner radius, so a large radius is
  what gives the thick lensing border on the sides and bottom.
- Thick, slightly frosted slab: `ThickGlassView` retunes the backdrop's private `glassBackground` filter on
  every layout: `inputBlurRadius` 5 (blur opacities 1), inner refraction height 86 / amount -110, outer refraction
  height 36 / amount 22 (variant 11 ships blur 0, inner 20 / -50, outer 16 / 10). The white specular rim (layer `@3`) is hidden:
  the user asked for no bright line along the bottom edge.
- Tint inside the glass, as fractions of the capsule height (measured from the reference video): solid black
  over the top 47% (or down to notch height + 40, whichever is lower), then a soft fade (half linear, half
  smoothstep, 14 stops) ending at ~90%: black alpha 1 → 0.06. A milky white haze is its own gradient from where the fade starts to the
  bottom edge, easing in (t^1.6) up to 0.16, so the white keeps building toward the bottom. The
  fade only opens up as the capsule grows (`reveal` = (height − 180) / 220, clamped), so the pill and the
  mid-morph frames stay dark like the reference. Text keeps its tight dark shadow.
- The same capsule is the collapsed pill (notch width + 90 by notch height + 26): at that size it is black
  all the way down.

**Motion (reference: the iOS notch-to-Spotlight video)**
- One `IslandGlass` view is resized, not scaled: it is `Animatable` over width and height, so every spring
  frame re-lays out the glass and the corners and lens edge stay true. hidden = notch size (faded out),
  collapsed = pill, expanded = 480 by content height.
- Open: `spring(response 0.5, damping 0.78)`; close: `spring(0.4, 1.0)`. Content comes in with blur 10 + fade
  + scale 0.92 from the top, 0.06 s after the glass starts; it leaves with a 0.16 s blur-out.
- Content is inset 28 pt from the left/right edges and 24 pt from the bottom so nothing sits on the rim.

**Layout, like the compose sheet**
- Title bar row under the notch: agent name 15 pt semibold white on the left (the sheet's "New Message"),
  folder and "1/3" after it in secondary white (0.55); on the right a collapse button drawn as a small
  circular glass-like control (24 pt circle, white 0.12 fill, `chevron.up` 11 pt).
- Below it the request title as a large heading: 20 pt semibold white, then the detail in 13 pt white 0.7.
- Field rows, separated by hairlines (1 px white 0.14, full content width), each row 40–44 pt tall:
  - question header / question text, when shown, is a row label in white 0.55 (like "To" / "Subject").
  - option rows: label 14 pt white, description 12 pt white 0.55 under it; the selection mark sits at the
    right end: `checkmark.circle.fill` in systemBlue when selected, `circle` white 0.35 when not (multi-select
    uses `checkmark.square.fill` / `square`). Hover gives the row a white 0.06 fill.
  - text field row: placeholder in white 0.4, no box, just the row with its hairline.
  - action card: the SF Symbol for the action kind 18 pt next to the title; detail in a body block; the note
    field as a row; the password warning as a row with `lock.fill`, systemOrange text.
- Bottom toolbar row (after a hairline): primary action on the left as a filled capsule in systemBlue,
  white 14 pt semibold text, 32 pt tall, 18 pt horizontal padding, `paperplane.fill` icon before "Submit"
  (question) / `checkmark` before "Done" (action) / no icon for "Got it" (notify). Secondary action on the
  right as plain text white 0.6 ("Decline", "Can't do it"). Disabled primary: systemBlue at 0.35.
- Collapsed pill stays solid black (it merges with the notch).
