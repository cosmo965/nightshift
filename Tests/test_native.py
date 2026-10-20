"""Boundary tests against the compiled production hook executable."""
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "dist/Nightshift.app/Contents/MacOS/Nightshift"

class NativeTests(unittest.TestCase):
    def test_standalone_setup_and_universal_event_adapter(self):
        import os
        with tempfile.TemporaryDirectory(prefix="nightshift-standalone-", dir=ROOT / ".build") as temp:
            home = Path(temp) / "home"
            state = Path(temp) / "state"
            command = ["python3", str(ROOT / "scripts/configure-hooks.py"), "--config-root", str(home), "--data", str(state)]
            setup = subprocess.run(command, capture_output=True, text=True, check=True, timeout=5)
            self.assertIn("ClaudeBar is not required", setup.stdout)
            for provider, config in (("codex", home / ".codex/hooks.json"), ("claude", home / ".claude/settings.json")):
                installed = json.loads(config.read_text())
                hook = installed["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
                self.assertIn(f"--hook {provider}", hook)
                self.assertNotIn("claudebar", hook.lower())
            for provider, host in (("codex", "example.terminal"), ("claude", "example.editor"), ("custom-agent", "example.desktop")):
                payload = {"session_id": provider, "hook_event_name": "UserPromptSubmit",
                           "transcript_path": str(Path(temp) / "session.jsonl"), "prompt": "PRIVATE"}
                env = {**os.environ, "__CFBundleIdentifier": host}
                subprocess.run([str(BINARY), "--hook", provider, "--data", str(state)],
                               input=json.dumps(payload), text=True, env=env, check=True, capture_output=True, timeout=5)
            events = [json.loads(path.read_text()) for path in (state / "inbox").glob("*.json")]
            self.assertEqual({event["provider"] for event in events}, {"codex", "claude", "custom-agent"})
            self.assertEqual({event["host"] for event in events}, {"example.terminal", "example.editor", "example.desktop"})
            self.assertTrue(all(event["transcriptPath"].endswith(".jsonl") for event in events))
            self.assertNotIn("PRIVATE", json.dumps(events))

    def test_helper_inspection_is_read_only(self):
        helper = ROOT / "dist/Nightshift.app/Contents/Resources/NightshiftLidHelper"
        result = subprocess.run([str(helper), "--inspect"], capture_output=True, text=True, check=True, timeout=3)
        report = json.loads(result.stdout)
        self.assertTrue(report["readOnly"])
        self.assertIn("sleepDisabled", report)

    def test_privileged_setup_requires_administrator(self):
        import os
        if os.geteuid() == 0:
            self.skipTest("This test must run unprivileged")
        helper = ROOT / "dist/Nightshift.app/Contents/Resources/NightshiftLidHelper"
        result = subprocess.run([str(helper), str(os.getuid())], capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 1)
        script = ROOT / "dist/Nightshift.app/Contents/Resources/install-lid-helper.sh"
        result = subprocess.run(["/bin/bash", str(script)], capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 1)
    def test_hook_writes_only_sanitized_event(self):
        with tempfile.TemporaryDirectory(prefix="nightshift-", dir=ROOT / ".build") as temp:
            # Larger than a pipe read: validates the entire stdin stream is consumed.
            payload = {"session_id": "boundary-test", "hook_event_name": "UserPromptSubmit", "turn_id": "turn-1",
                       "cwd": "/example/project", "prompt": "PRIVATE" * 100000,
                       "tool_input": {"password": "PRIVATE"}}
            completed = subprocess.run([str(BINARY), "--hook", "codex", "--data", temp],
                                       input=json.dumps(payload), text=True, capture_output=True, timeout=5)
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(json.loads(completed.stdout), {})
            files = list((Path(temp) / "inbox").glob("*.json"))
            self.assertEqual(len(files), 1)
            event = json.loads(files[0].read_text())
            self.assertEqual(event["session"], "boundary-test")
            self.assertEqual(event["name"], "UserPromptSubmit")
            self.assertEqual(event["label"], "project")
            self.assertNotIn("PRIVATE", files[0].read_text())
            self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)

    def test_invalid_hook_never_blocks_agent(self):
        with tempfile.TemporaryDirectory(prefix="nightshift-", dir=ROOT / ".build") as temp:
            result = subprocess.run([str(BINARY), "--hook", "codex", "--data", temp],
                                    input="not json", text=True, capture_output=True, timeout=3)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout), {})
            self.assertFalse(list(Path(temp).rglob("*.json")))

    def test_installer_isolated_home_and_remove(self):
        with tempfile.TemporaryDirectory(prefix="nightshift-home-", dir=ROOT / ".build") as temp:
            config = Path(temp) / ".codex/hooks.json"
            config.parent.mkdir()
            original = {"hooks": {"Stop": [{"hooks": [{"command": "other-hook", "type": "command"}]}]}}
            config.write_text(json.dumps(original))
            command = ["python3", str(ROOT / "scripts/configure-hooks.py"), "--provider", "codex", "--config-root", temp]
            subprocess.run(command, check=True, capture_output=True)
            configured = json.loads(config.read_text())
            self.assertEqual(configured["hooks"]["Stop"][0]["hooks"][0]["command"], "other-hook")
            self.assertTrue(list(config.parent.glob("hooks.json.nightshift-backup-*")))
            subprocess.run(command + ["--remove"], check=True, capture_output=True)
            self.assertEqual(json.loads(config.read_text()), original)

    def test_setup_migrates_default_data_directory(self):
        with tempfile.TemporaryDirectory(prefix="nightshift-migration-", dir=ROOT / ".build") as temp:
            root = Path(temp)
            app = root / "Nightshift.app"
            binary = app / "Contents/MacOS/Nightshift"
            binary.parent.mkdir(parents=True)
            binary.touch()
            legacy = root / "Caffeine Data"
            legacy.mkdir()
            (legacy / "state.json").write_text('{"preserved": true}')
            command = ["python3", str(ROOT / "scripts/configure-hooks.py"),
                       "--app", str(app), "--config-root", str(root / "home")]
            subprocess.run(command + ["--dry-run"], capture_output=True, check=True, timeout=5)
            self.assertTrue((legacy / "state.json").exists())
            self.assertFalse((root / "home").exists())
            subprocess.run(command, capture_output=True, check=True, timeout=5)
            current = root / "Nightshift Data"
            self.assertEqual(json.loads((current / "state.json").read_text()), {"preserved": True})
            self.assertFalse(legacy.exists())
            config = json.loads((root / "home/.codex/hooks.json").read_text())
            hook = config["hooks"]["Stop"][0]["hooks"][0]["command"]
            self.assertIn(str(current), hook)
            # Existing current data must never be overwritten by a legacy directory.
            legacy.mkdir()
            (legacy / "other.json").write_text('{}')
            subprocess.run(command, capture_output=True, check=True, timeout=5)
            self.assertTrue((legacy / "other.json").exists())
            self.assertTrue((current / "state.json").exists())

    def test_native_hook_cost(self):
        with tempfile.TemporaryDirectory(prefix="nightshift-bench-", dir=ROOT / ".build") as temp:
            durations = []
            payload = json.dumps({"session_id": "bench", "hook_event_name": "Stop"})
            for _ in range(20):
                start = time.perf_counter()
                subprocess.run([str(BINARY), "--hook", "codex", "--data", temp],
                               input=payload, text=True, capture_output=True, check=True, timeout=3)
                durations.append((time.perf_counter() - start) * 1000)
            durations.sort()
            print(f"Native hook, including process startup: median {durations[10]:.1f} ms, max {max(durations):.1f} ms")
            self.assertEqual(len(list((Path(temp) / "inbox").glob("*.json"))), 20)

if __name__ == "__main__":
    unittest.main()
