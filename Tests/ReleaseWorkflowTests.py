"""Exercise the privileged workflow's inline shell without network or credentials."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text()


def step(name):
    content = WORKFLOW.split(f"      - name: {name}\n", 1)[1]
    content = content.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
    return textwrap.dedent(content)


class ReleaseWorkflowTests(unittest.TestCase):
    def run_step(self, name, release_state="missing", version="1.2.3+7", tag="v1.2.3"):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            log = folder / "calls.jsonl"
            gh = folder / "gh"
            gh.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import base64, json, os, sys
                with open(os.environ["CALL_LOG"], "a") as log:
                    log.write(json.dumps(sys.argv[1:]) + "\\n")
                if sys.argv[1] == "api":
                    print(base64.b64encode(os.environ["TEST_VERSION"].encode()).decode())
                elif sys.argv[1:3] == ["release", "view"]:
                    state = os.environ["TEST_RELEASE_STATE"]
                    if state == "missing":
                        sys.exit(1)
                    print({"draft": "true", "published": "false"}.get(state, state))
                elif sys.argv[1:3] not in (["release", "create"], ["release", "edit"]):
                    sys.exit(2)
            '''))
            gh.chmod(0o700)
            env = {**os.environ, "PATH": str(folder) + os.pathsep + os.environ["PATH"],
                   "GITHUB_REPOSITORY": "example/luxit", "RELEASE_TAG": tag,
                   "TEST_RELEASE_STATE": release_state, "TEST_VERSION": version, "CALL_LOG": str(log)}
            result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", step(name)],
                                    env=env, text=True, capture_output=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_prepared_draft_is_published_without_replacing_assets(self):
        result, calls = self.run_step("Create or publish GitHub release", "draft")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1], ["release", "edit", "v1.2.3", "--repo", "example/luxit", "--draft=false"])
        self.assertEqual(len(calls), 2)

    def test_published_release_is_untouched(self):
        result, calls = self.run_step("Create or publish GitHub release", "published")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)

    def test_absent_release_retains_verified_tag_creation(self):
        result, calls = self.run_step("Create or publish GitHub release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1][:3], ["release", "create", "v1.2.3"])
        self.assertIn("--verify-tag", calls[-1])
        self.assertIn("--generate-notes", calls[-1])

    def test_unknown_state_cannot_publish(self):
        result, calls = self.run_step("Create or publish GitHub release", "null")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)

    def test_tag_and_version_guards(self):
        for tag in ("v1.2.3", "v0.13.1"):
            result, _ = self.run_step("Validate release tag", tag=tag)
            self.assertEqual(result.returncode, 0)
        for tag in ("main", "v1.2.3; exit 0", "v1.2.3-rc1"):
            result, calls = self.run_step("Validate release tag", tag=tag)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, [])
        for version, expected in (("1.2.3+7", 0), ("1.2.4+7", 1), ("01.2.3+7", 1), ("1.2.3+0", 1)):
            result, _ = self.run_step("Verify tag matches VERSION", version=version)
            self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == "__main__":
    program = unittest.main(exit=False)
    if not program.result.wasSuccessful():
        raise SystemExit(1)
    print("ReleaseWorkflowTests passed (draft publication, immutable retries, tag/version guards)")
