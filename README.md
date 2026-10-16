# AskIsland

A notch panel for coding agents. When an agent needs you (pick an option, answer a question, do something on
the Mac or the phone, type a password, log in), it drops down from the notch, says what to do, and you answer
right there. The agent waits for your answer. Everything else stays out of the way: the island only exists
while something is waiting, and clicks outside it go to the window underneath.

Forked from [wxtsky/CodeIsland](https://github.com/wxtsky/CodeIsland) (MIT) and cut down to this one job.

## Requirements

- macOS 26 or later, a Mac with a notch (it also works on other screens, centred at the top)
- Xcode 26 or later (Swift 6)

## Install

```bash
AskIsland/scripts/install.sh
```

This builds a release, installs `~/Applications/AskIsland.app` (started at login by a LaunchAgent), the
`ask-island` CLI in `~/.local/bin`, and the Claude Code hooks in `~/.claude/settings.json`.

## Use

Any agent that can run a shell command can ask you something:

```bash
ask-island ask "Which environment should this deploy to?" -o "Staging::Check it there first" -o Production
ask-island do "Tap Allow on the iPhone" --kind phone --detail "Settings > Privacy > Local Network"
ask-island notify "Build finished"
```

The command blocks until you answer and prints the result. Exit codes: 0 answered, 2 AskIsland not running,
3 declined, 4 timed out, 5 dismissed. `--json` prints the full response. Titles, details and options are
shown as the agent wrote them, in its own language.

To let an agent know it can reach you, add one line to its `AGENTS.md` (or `CLAUDE.md`):

```
When you need me to choose, confirm, or do something by hand, run `ask-island ask|do` and wait for the answer.
```

Claude Code needs nothing else: its own questions (AskUserQuestion) and permission prompts arrive through the
installed hook. If AskIsland is not running, Claude falls back to its own UI.

The header shows the session's name: Claude Code's session title, or `--session NAME` /
`ASK_ISLAND_SESSION` for other agents.

## Notes

- The glass uses private AppKit API (`NSGlassEffectView` variant 11 and its backdrop filter), so this is not
  for the App Store and may need retuning after a macOS update.
- Behaviour and visuals are specified in [AskIsland/SPEC.md](AskIsland/SPEC.md).
- Tests: `cd AskIsland && swift test`; `scripts/smoke-app.sh` runs the app and one real request over HTTP.
