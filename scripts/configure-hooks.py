#!/usr/bin/env python3
"""Set up Nightshift's built-in agent detection. Backs up configuration and preserves other hooks."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shlex
import tempfile

EVENTS = {
    "codex": ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
              "PermissionRequest", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Stop", "Interrupt"],
    "claude": ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
               "PostToolUseFailure", "PermissionRequest", "PermissionDenied", "Notification", "Elicitation", "ElicitationResult",
               "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Stop", "StopFailure"],
}
MARKER = "Nightshift-managed-hook-v1"

def merge(original, provider, binary, data, remove=False):
    document = json.loads(json.dumps(original))
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("Existing hooks must be a JSON object; configuration left unchanged")
    for event in list(hooks):
        groups = []
        for group in hooks[event]:
            kept = [h for h in group.get("hooks", []) if not any(
                marker in h.get("command", "") for marker in (MARKER, "Caffeine-managed-hook-v1", "AgentCoffee-managed-hook-v1"))]
            if kept:
                groups.append({**group, "hooks": kept})
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]
    if not remove:
        command = f"{shlex.quote(str(binary))} --hook {provider} --data {shlex.quote(str(data))} # {MARKER}"
        for event in EVENTS[provider]:
            # Synchronous native writes preserve hook order. No shell network calls, no agent decisions.
            hooks.setdefault(event, []).append({"hooks": [{"type": "command", "command": command, "timeout": 2}]})
    return document

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=["codex", "claude", "both"], default="both")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--data", type=Path)
    parser.add_argument("--config-root", type=Path, help="Override for an isolated test home")
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    script = Path(__file__).resolve()
    default_app = script.parents[2] if script.parent.name == "Resources" else script.parent.parent / "dist/Nightshift.app"
    app = (args.app or default_app).resolve()
    binary = app / "Contents/MacOS/Nightshift"
    if not binary.is_file():
        parser.error(f"Built executable not found at {binary}")
    legacy_data = app.parent / "Caffeine Data"
    default_data = app.parent / "Nightshift Data"
    data = (args.data or default_data).resolve()
    providers = ["codex", "claude"] if args.provider == "both" else [args.provider]
    # Validate every document before modifying any of them.
    pending = []
    for provider in providers:
        if args.config_root:
            path = args.config_root / (".codex/hooks.json" if provider == "codex" else ".claude/settings.json")
        elif provider == "codex":
            path = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "hooks.json"
        else:
            path = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "settings.json"
        original = json.loads(path.read_text()) if path.exists() else {}
        document = merge(original, provider, binary, data, args.remove)
        pending.append((path, document))
    if not args.data and not args.dry_run and not args.remove and not default_data.exists() and legacy_data.exists():
        legacy_data.rename(default_data)
    for path, document in pending:
        if args.dry_run:
            print(f"Would {'remove' if args.remove else 'merge'} Nightshift hooks in {path}")
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            backup = path.with_name(path.name + ".nightshift-backup-" + stamp)
            backup.write_bytes(path.read_bytes())
            backup.chmod(0o600)
        fd, tmp = tempfile.mkstemp(prefix=".nightshift-", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(document, handle, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        print(f"Updated {path}; existing unrelated hooks preserved")
    if not args.dry_run:
        print("Nightshift detects agent activity directly. ClaudeBar is not required.")
        print("Restart agent sessions. In Codex, review and trust the new hooks with /hooks.")
        print("Keep Nightshift running. Uninstall with the same command plus --remove.")

if __name__ == "__main__":
    main()
