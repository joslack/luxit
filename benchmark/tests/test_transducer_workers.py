import json

from benchmark.workers.transducer_worker_utils import parse_transcript_output


def test_parse_transcript_output_from_plain_text() -> None:
    stdout = "INFO loading\nhello world"
    parsed = parse_transcript_output(stdout)
    assert parsed["text"] == "hello world"
    assert parsed["segments"] == []
    assert parsed["words"] == []


def test_parse_transcript_output_from_json() -> None:
    payload = {
        "text": "foo bar",
        "segments": [{"text": "foo bar", "start": 0.0, "end": 1.0}],
        "words": [{"word": "foo", "start": 0.0, "end": 0.3}],
    }
    stdout = json.dumps(payload)
    parsed = parse_transcript_output(stdout)
    assert parsed["text"] == "foo bar"
    assert parsed["segments"] == payload["segments"]
    assert parsed["words"] == payload["words"]


def test_parse_json_logs_with_non_text_lines() -> None:
    stdout = "\n".join(
        [
            "WARNING prewarm",
            json.dumps({"event": "ready"}),
            json.dumps({"text": "final", "backend_ms": 12.5}),
            "tail",
        ]
    )
    parsed = parse_transcript_output(stdout)
    assert parsed["text"] == "final"
    assert parsed["metadata"]["raw_line_count"] == 4
    assert parsed["backend_ms"] == 12.5
