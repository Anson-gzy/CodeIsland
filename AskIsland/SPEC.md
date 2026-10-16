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
  source agent "claude", cwd, session_id, sessionName = the session's title (last `custom-title` line of
  `transcript_path`, read backwards in 256 KB chunks; else found by session id under `~/.claude/projects`). Answered → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
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
  "codex" if any `CODEX_` env var, else "cli"; sessionName = --session, else env `ASK_ISLAND_SESSION`, else the
  title of the Claude Code session in `CLAUDE_CODE_SESSION_ID`.
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
  pending request. Header: session name (`source.sessionName`, else `source.agent`, else "Agent") · last path component of `source.cwd` ·
  "1/3" when more than one, and a chevron that collapses.
- Pending, collapsed: a black pill the notch's width plus 32 pt wings on each side, showing the first request
  in one line; click expands. A new arrival while collapsed keeps it collapsed and pulses the glyph once.
- Arrival is silent (no sound) and never steals focus.

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
  edge at the screen top. It only takes mouse events while the pointer is over the island: the root view
  reports the island's size (`hitSize`, surface + shoulders) and a 30 Hz pointer poll, running only while
  something is pending, flips `ignoresMouseEvents` (transparent pixels of the panel do NOT pass clicks through
  on their own). `ignoresMouseEvents` stays true while nothing is pending.
- One surface (`IslandSurface`), top-anchored and horizontally centered, morphs between three sizes:
  hidden = notchWidth × notchHeight (faded out); collapsed = notchWidth + 24 × notchHeight + 22 (plain black
  notch extension, badge below the notch); expanded = 480 × measured content height (clamped to the window).
  Curves and content transitions: see "Motion" under Visual style.
- First arrival: hidden → expanded (grows from the notch). Resolving the last request: expanded → hidden with
  the same shrink as collapsing (close spring, black curtain, into notch size, fully opaque); the surface only
  fades out 0.6 s later, once it sits inside the notch.

## Visual style (reference: a Liquid Glass "New Message" compose sheet)

The expanded island is one slab of clear lens glass hanging from the notch (iOS Spotlight / "Search or Ask"
look), styled like a macOS 26 compose sheet. The island's own chrome (buttons, placeholders) is English; the
title, detail, questions and options are the agent's words, shown verbatim in whatever language it writes.

**Shape**
- Flat top on the screen's top edge that flares out into the menu bar through concave shoulders (like the
  hardware notch), straight sides, round bottom corners. `NotchShape` draws it; shoulder 14 pt expanded, 4 pt
  collapsed. Bottom radius 40 expanded, 12 collapsed, interpolated by the morph and clamped to height / 2.
- No highlight along the top: the glass's top corners are pushed above the screen edge (glass frame = height +
  2r, offset −2r), and a black `NotchShape` covers the band under the notch (solid to notch height, fading out
  by 2× notch height), so only the flared shoulders and the bottom corners show.

**Glass (expanded)**
- `ClearLensGlass` (`_variant` 11) inside `IslandSurface`. Thick, slightly frosted slab: `ThickGlassView` retunes
  the backdrop's private `glassBackground` filter on every layout and again on key-window / app-activation
  changes. Focus changes reach the glass as `_effectiveGlassMaterialContext` and its private
  `_windowChangedKeyState`; the stock values (blur 0, thin refraction) come back a few frames later, so the
  view skips `_windowChangedKeyState` and holds its values every frame for 0.5 s after a context change
  (otherwise a click anywhere flashed clearer glass, then blur):
  `inputBlurRadius` 3 (blur opacities 1), face color matrix on (`inputFaceOpacity` 1,
  `inputFaceColorMatrixWhite` 0.68: the backdrop is capped at mid grey, like Voice Pill's glass, so white text
  stays legible over a white window), inner refraction height 86 / amount -110, outer refraction height 36 /
  amount 22 (variant 11 ships blur 0, inner 20 / -50, outer 16 / 10). The white specular rim (layer `@3`) stays
  as the thin bright line along the bottom; thinned through its private `CASDFKeyFillHighlightEffect`:
  `keyHeight` / `fillHeight` 1.5 (default 3.5), `diffuseHeightScale` 4 (default 8).
- Tint inside the glass, as fractions of the visible height (measured from the reference video, mapped past
  the hidden top inset): solid black over the top 47%, then
  a soft fade (half linear, half smoothstep, 14 stops) ending at ~90%: black alpha 1 → 0, leaving the grey
  glass at the bottom (no white haze). Pure proportions at any
  height (a short notify card fades like a tall one); mid-morph darkness comes from the black curtain below.
- Text (not buttons or fields) gets a soft dark halo (`textHalo`: black 0.45, radius 2.5) for legibility.

**Collapsed**
- No glass: a plain black `NotchShape` that extends the notch down by 22 pt; in that strip, like a live
  activity: a blue SF Symbol (`systemBlue`, the Submit button's blue) for what is waiting (question `questionmark.bubble.fill`, notify `bell.fill`,
  action by kind: `desktopcomputer`, `iphone`, `lock.fill`, `person.badge.key.fill`, else `hand.raised.fill`),
  the first request's own title (12 pt medium, white 0.85, one line, tail-truncated), then "+N" in a small
  white 0.14 capsule when more are waiting.
- Hover: the pill swells by 20 pt wide / 4 pt tall on a `spring(0.3, 0.65)`, the title brightens to white and
  a small `chevron.down` slides in at the end.

**Motion (reference: the iOS notch-to-Spotlight video)**
- `IslandSurface` is resized, not scaled: `Animatable` over width, height and `glass` (0 = black pill, 1 =
  glass), so every spring frame re-lays out the shape and the corners and lens edge stay true. The black
  curtain follows `glass`³: on the way down it closes over the glass early, so the shrinking slab reads as the
  dark notch rather than a grey block; on the way up the glass opens near full size. The refraction bands are
  fixed in points, so they scale with `glass`³ too (otherwise they cover a shrinking slab and smear it), and the
  glass is never faded with opacity (alpha below 1 on the backdrop flashes the stock heavy blur).
- The glass rebuilds its backdrop filters after a shape change, after layout: `ThickGlassView` retunes on
  layout and once more right after the transaction commits, or the morph runs on the stock filter.
- Content is clipped by `IslandClipShape`, animated with the same spring, so it never spills outside the
  shape while it grows or shrinks.
- Open: `spring(response 0.5, damping 0.78)`; close: `spring(0.52, 0.9)`. Content comes in with blur 10 + fade
  + scale 0.92 from the top, 0.06 s after the surface starts; it leaves with a 0.18 s blur-out + scale 0.94.
- Content is inset 28 pt from the left/right edges and 24 pt from the bottom so nothing sits on the rim.

**Layout, like the compose sheet**
- Title bar row under the notch: session name (else agent) 15 pt semibold white, one line, on the left (the sheet's "New Message"),
  folder and "1/3" after it in secondary white (0.55); on the right a collapse button drawn as a small
  circular glass-like control (24 pt circle, white 0.12 fill, `chevron.up` 11 pt).
- Below it the request title as a large heading: 20 pt semibold white, then the detail in 13 pt white 0.7.
- Rows (no hairlines between options; a hairline only between questions):
  - question header / question text, when shown, is a row label in white 0.55 (like "To" / "Subject").
  - option rows: label 14 pt white, description 12 pt white 0.55 under it; the selection mark sits at the
    right end: `checkmark.circle.fill` in systemBlue when selected, `circle` white 0.35 when not (multi-select
    uses `checkmark.square.fill` / `square`). Hover: a white 0.12 continuous-corner tile (radius 12) behind the
    row, bleeding 10 pt past the text column, eased in over 0.12 s.
  - text fields (question "Other", action note): a frosted box, white 0.1 fill + white 0.18 hairline border,
    radius 12, at least 38 pt tall, same 10 pt bleed. The field wraps (vertical axis, 1–4 lines) instead of
    scrolling sideways, so typed text and IME marked text never run under the right edge.
  - action card: the SF Symbol for the action kind 18 pt next to the title; detail in a body block; the note
    field; the password warning as a row with `lock.fill`, systemOrange text.
- Bottom toolbar, right-aligned like the compose sheet's "Save draft" / "Send": secondary then primary, both
  Liquid Glass capsules (`glassEffect(.regular.interactive())`, 36 pt tall, 14 pt semibold white): secondary
  is clear glass ("Decline", "Can't do it"), primary is blue-tinted glass ("Submit", "Done", "Got it"; disabled:
  tint 0.35, label 0.6). Not the system `.glass` button styles: those grey out whenever the non-activating
  panel is not the key window.
- Collapsed pill stays solid black (it merges with the notch).
