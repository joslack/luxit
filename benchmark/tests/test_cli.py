import subprocess
import sys
import unittest


class CliTests(unittest.TestCase):
    def test_help(self):
        completed = subprocess.run(
            [sys.executable, "-m", "sttbench.cli", "--help"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0)
        self.assertIn("local STT backends", completed.stdout)


if __name__ == "__main__":
    unittest.main()
