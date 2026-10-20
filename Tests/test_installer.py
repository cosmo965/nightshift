import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("installer", pathlib.Path(__file__).parents[1] / "scripts/configure-hooks.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class InstallerTests(unittest.TestCase):
    def test_claudebar_hooks_coexist_with_standalone_detection(self):
        existing = {"type": "command", "command": "bash /hooks/claudebar-hook.sh", "async": True}
        for provider in ("claude", "codex"):
            original = {"hooks": {"Stop": [{"matcher": "*", "hooks": [existing]}]}}
            args = (provider, pathlib.Path("/app/Nightshift"), pathlib.Path("/data"))
            merged = module.merge(original, *args)
            self.assertEqual(merged["hooks"]["Stop"][0], original["hooks"]["Stop"][0])
            self.assertEqual(module.merge(merged, *args, remove=True), original)
            self.assertNotIn("claudebar", merged["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"])

    def test_preservation_idempotence_removal(self):
        original = {"unrelated": True, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "existing-hook"}]}]}}
        args = ("codex", pathlib.Path("/space ' quote/Nightshift"), pathlib.Path("/state path"))
        first = module.merge(original, *args)
        second = module.merge(first, *args)
        self.assertEqual(first, second)
        self.assertEqual(module.merge(second, *args, remove=True), original)
        self.assertEqual(original["hooks"]["Stop"][0]["hooks"][0]["command"], "existing-hook")

    def test_input_is_not_mutated(self):
        original = {}
        module.merge(original, "claude", pathlib.Path("/app"), pathlib.Path("/data"))
        self.assertEqual(original, {})

    def test_rename_replaces_legacy_hooks(self):
        for name in ("AgentCoffee", "Caffeine"):
            with self.subTest(previous_name=name):
                original = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": f"/old/{name} # {name}-managed-hook-v1"}]}]}}
                merged = module.merge(original, "codex", pathlib.Path("/new/Nightshift"), pathlib.Path("/state"))
                self.assertEqual(len(merged["hooks"]["Stop"]), 1)
                self.assertNotIn(name, str(merged))
                self.assertIn("Nightshift-managed-hook-v1", str(merged))

if __name__ == "__main__":
    unittest.main()
