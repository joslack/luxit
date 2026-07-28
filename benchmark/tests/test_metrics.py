import unittest

from sttbench.metrics import character_error_rate, keyword_recall, score, word_error_rate


class MetricsTests(unittest.TestCase):
    def test_word_error_rate_ignores_case_and_punctuation(self):
        self.assertEqual(word_error_rate("Core ML, please.", "core ml please"), 0.0)

    def test_word_error_rate_counts_substitution(self):
        self.assertAlmostEqual(word_error_rate("one two three", "one too three"), 1 / 3)

    def test_keyword_recall_normalizes_terms(self):
        self.assertEqual(keyword_recall(["Whisper.cpp", "M3 Pro"], "whisper cpp on an M3 Pro"), 1.0)

    def test_score_reports_exact_normalized(self):
        self.assertTrue(score("Hello, Luxit!", "hello Luxit")["exact_normalized"])
        self.assertEqual(character_error_rate("Hello, Luxit!", "hello Luxit"), 0.0)


if __name__ == "__main__":
    unittest.main()
