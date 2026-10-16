#!/bin/bash
# Build AskIsland and install it for this user:
#   ~/Applications/AskIsland.app            the island (agent app, starts at login)
#   ~/.local/bin/ask-island                 the CLI agents call
#   ~/Library/LaunchAgents/local.askisland.plist
#   Claude Code hooks: PermissionRequest + Notification → `ask-island hook`, added to the live
#   ~/.claude/settings.json and to the maat template (~/.agents/claude-config/settings.json) so a
#   later `maat render` keeps them. Old CodeIsland hook entries are removed from the live file.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build -c release -q
BIN=$(swift build -c release --show-bin-path)

APP="$HOME/Applications/AskIsland.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/AskIsland" "$APP/Contents/MacOS/AskIsland"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.askisland</string>
  <key>CFBundleName</key><string>AskIsland</string>
  <key>CFBundleExecutable</key><string>AskIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP" >/dev/null 2>&1

mkdir -p "$HOME/.local/bin"
cp "$BIN/ask-island" "$HOME/.local/bin/ask-island"

PLIST="$HOME/Library/LaunchAgents/local.askisland.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.askisland</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AskIsland</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/local.askisland" 2>/dev/null || true
pkill -x AskIsland 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

python3 - "$HOME/.claude/settings.json" "$HOME/.agents/claude-config/settings.json" <<'EOF'
import json, sys, shutil
live, template = sys.argv[1], sys.argv[2]
OURS = {
    "PermissionRequest": {"matcher": "", "hooks": [{"type": "command", "command": "${HOME}/.local/bin/ask-island hook", "timeout": 86400}]},
    "Notification": {"matcher": "", "hooks": [{"type": "command", "command": "${HOME}/.local/bin/ask-island hook", "timeout": 10}]},
}
def patch(path, home, drop_codeisland, backup):
    with open(path) as f: d = json.load(f)
    hooks = d.setdefault("hooks", {})
    for ev in list(hooks):
        kept = []
        for m in hooks[ev]:
            m["hooks"] = [h for h in m.get("hooks", [])
                          if "ask-island hook" not in h.get("command", "")
                          and not (drop_codeisland and "codeisland-hook.sh" in h.get("command", ""))]
            if m["hooks"]: kept.append(m)
        if kept: hooks[ev] = kept
        else: del hooks[ev]
    for ev, entry in OURS.items():
        e = json.loads(json.dumps(entry).replace("${HOME}", home))
        hooks.setdefault(ev, []).append(e)
    if backup: shutil.copy(path, path + ".askisland.bak")
    with open(path, "w") as f: json.dump(d, f, ensure_ascii=False, indent=2); f.write("\n")
import os
patch(live, os.path.expanduser("~"), drop_codeisland=True, backup=True)
patch(template, "${HOME}", drop_codeisland=False, backup=False)  # in git; no backup
print("hooks installed")
EOF

sleep 1
"$HOME/.local/bin/ask-island" notify "AskIsland installed" --detail "Agents will ask you here when they need you." --agent install >/dev/null \
  && echo "AskIsland running" || echo "AskIsland not reachable yet"
