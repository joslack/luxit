from __future__ import annotations

import re
import unicodedata
from typing import Iterable


def _distance(left: list[str], right: list[str]) -> int:
    if len(left) < len(right):
        left, right = right, left
    previous = list(range(len(right) + 1))
    for row, left_item in enumerate(left, start=1):
        current = [row]
        for column, right_item in enumerate(right, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column] + 1,
                    previous[column - 1] + (left_item != right_item),
                )
            )
        previous = current
    return previous[-1]


def normalize_words(text: str) -> list[str]:
    text = unicodedata.normalize("NFKC", text).casefold()
    text = re.sub(r"[^\w']+", " ", text, flags=re.UNICODE)
    return [word.strip("'") for word in text.split() if word.strip("'")]


def word_error_rate(reference: str, hypothesis: str) -> float:
    expected = normalize_words(reference)
    actual = normalize_words(hypothesis)
    if not expected:
        return 0.0 if not actual else 1.0
    return _distance(expected, actual) / len(expected)


def character_error_rate(reference: str, hypothesis: str) -> float:
    # CER uses the same case/punctuation normalization as WER so capitalization
    # policy is not mistaken for recognition failure.
    expected = list(" ".join(normalize_words(reference)))
    actual = list(" ".join(normalize_words(hypothesis)))
    if not expected:
        return 0.0 if not actual else 1.0
    return _distance(expected, actual) / len(expected)


def keyword_recall(keywords: Iterable[str], hypothesis: str) -> float | None:
    normalized = " ".join(normalize_words(hypothesis))
    expected = [" ".join(normalize_words(keyword)) for keyword in keywords]
    expected = [keyword for keyword in expected if keyword]
    if not expected:
        return None
    return sum(keyword in normalized for keyword in expected) / len(expected)


def score(reference: str, hypothesis: str, keywords: Iterable[str] = ()) -> dict[str, float | bool | None]:
    wer = word_error_rate(reference, hypothesis)
    cer = character_error_rate(reference, hypothesis)
    return {
        "wer": wer,
        "word_accuracy": max(0.0, 1.0 - wer),
        "cer": cer,
        "character_accuracy": max(0.0, 1.0 - cer),
        "keyword_recall": keyword_recall(keywords, hypothesis),
        "exact_normalized": normalize_words(reference) == normalize_words(hypothesis),
    }
