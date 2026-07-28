from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from benchmark.sttbench.server import BenchmarkApplication


class RatingStoreTests(unittest.TestCase):
    def test_ratings_are_persisted_and_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = BenchmarkApplication(Path(directory))
            first = app.upsert_rating(
                {
                    "result_id": "result-1",
                    "recording_id": "recording-1",
                    "backend_id": "backend-1",
                    "rating": "useful",
                    "corrected_text": "first guess",
                }
            )
            second = app.upsert_rating(
                {
                    "result_id": "result-1",
                    "recording_id": "recording-1",
                    "backend_id": "backend-1",
                    "rating": "wrong",
                    "corrected_text": "corrected transcript",
                }
            )

            ratings = app.list_ratings()
            self.assertIn("result-1", ratings)
            self.assertEqual(ratings["result-1"]["rating"], "wrong")
            self.assertEqual(ratings["result-1"]["corrected_text"], "corrected transcript")
            self.assertEqual(ratings["result-1"]["created_at"], first["created_at"])
            self.assertTrue(second["updated_at"] >= first["updated_at"])
            self.assertEqual(len(app.ratings_path.read_text(encoding="utf-8").splitlines()), 2)

    def test_invalid_rating_value_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = BenchmarkApplication(Path(directory))
            with self.assertRaises(ValueError):
                app.upsert_rating(
                    {
                        "result_id": "result-1",
                        "rating": "terrible",
                    }
                )


if __name__ == "__main__":
    unittest.main()
