# Transcript corrections

Corrections replace recurring recognition mistakes after transcription. They
work with both Parakeet and Whisper, for Caps Lock dictation and microphone +
computer recordings. They do not depend on the model's vocabulary hints.

This feature starts with no rules. Add only the replacements you want applied
automatically; Luxit does not infer or download a correction dictionary.

## Configure in Settings

Open **Settings → Corrections**, choose **Add replacement**, enter the phrase
to replace and its replacement, then **Save** (or **⌘S**). Enable **Pattern**
for a regular expression. **Cancel** discards unsaved changes. Remove a row
with its minus button and save to disable that rule.

## Configure with a file

Settings reads and writes this same UTF-8 JSON file:

```text
~/Library/Application Support/EdgeWhisper/corrections.json
```

The file may not exist until you first save a rule. You can create it yourself
or generate it with a script. `EdgeWhisper` is Luxit's existing storage-folder
name, retained across upgrades.

```json
{
  "replacements": [
    {
      "from": "local speech tool",
      "to": "Luxit"
    },
    {
      "from": "Luke\\s+(sit|set)",
      "to": "Luxit",
      "isPattern": true
    },
    {
      "from": "(ticket|issue)\\s+number\\s+(\\d+)",
      "to": "$1 #$2",
      "isPattern": true
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `replacements` | Required array, applied in its listed order. |
| `from` | Required nonblank phrase, or regex when `isPattern` is true. |
| `to` | Required nonblank replacement; a capture template in Pattern mode. |
| `isPattern` | Optional boolean; defaults to `false`. |

Use ordinary JSON without comments or trailing commas. To disable all rules,
save `{"replacements": []}` or remove the file. No other top-level fields,
tier lists, or glossary entries are needed.

Luxit checks for file changes before applying corrections and when opening
Settings. Edits take effect on the next transcription without restarting.
Rules are cached and compiled again only when the file changes or you save
from Settings. Reopen the editor after editing the file elsewhere; saving an
already-open editor writes its current draft back to the file.

## Matching and patterns

Both modes ignore case and match complete words or phrases. A match cannot
start or end inside a larger word, number, or underscore-separated identifier.
For example, a rule for `underwrite` does not change `underwriter`.

Phrase mode treats punctuation, dollar signs, and backslashes literally.
Spaces between words also match repeated whitespace, including line breaks.
The replacement uses the exact spelling and capitalization you provide.

Pattern mode uses Foundation's `NSRegularExpression` syntax. Luxit adds whole-word
boundaries around the entire pattern, including alternatives:

| Pattern as entered in Settings | Replacement | Example |
| --- | --- | --- |
| `Luke\s+(sit|set)` | `Luxit` | Both “Luke sit” and “Luke set” become “Luxit”. |
| `(ticket|issue)\s+number\s+(\d+)` | `$1 #$2` | “ticket number 42” becomes “ticket #42”. |
| `Luke(?=\s+sit)` | `Luxit` | “Luke sit” becomes “Luxit sit”; “Luke set” stays unchanged. |

Parentheses capture groups; `$1`, `$2`, etc. insert those groups in `to`.
`$0` inserts the complete match. Referencing a group that does not exist is
an error. Matches that consume no characters are ignored.

JSON needs an extra backslash: enter `\s+` in Settings, but write `"\\s+"`
in JSON. This is JSON escaping, not a different pattern language.

Rules run once each, in order. Later rules can match text produced by earlier
ones, so put specific corrections before broader ones and avoid unintended
chains. No ambiguous homophone replacements are enabled automatically.

## Generate rules with code

Any program that writes the JSON format above can configure Luxit. Write to a
temporary file in the same folder, then replace `corrections.json` atomically
so Luxit cannot read a partially written file. For example:

```python
import json
import os
import tempfile
from pathlib import Path

path = Path.home() / "Library/Application Support/EdgeWhisper/corrections.json"
rules = {
    "replacements": [
        {"from": r"Luke\s+(sit|set)", "to": "Luxit", "isPattern": True}
    ]
}
path.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8",
                                 dir=path.parent, delete=False) as temporary:
    json.dump(rules, temporary, ensure_ascii=False, indent=2)
    temporary.write("\n")
os.replace(temporary.name, path)
```

This example replaces the complete rule list. Load and modify the existing
JSON first if you want to keep other rules. The temporary file is private to
your user account, and replacing the destination preserves those permissions.

## Scope, failures, and privacy

Corrections run before new text is saved to history, counted in usage, or
pasted into another app. Conversation recording applies them to each completed
chunk; a pattern cannot span separate chunks. Changing the rules during a
recording affects later chunks as they finish transcription.

Existing saved transcripts are not rewritten. Removing a rule does not undo
corrections in older transcripts. Speaker labels use the corrected words and
their corresponding audio intervals; if timing cannot be aligned, the text
is preserved without fabricated timing information.

Invalid JSON, invalid patterns, or invalid capture references show an error
in Corrections. Settings rejects an invalid save. For an invalid external
file edit, the running app keeps its last valid rules in memory. On a fresh
launch with no valid rules loaded, transcription continues without corrections.
A regex execution budget prevents pathological patterns from hanging the
recorder; if it is exceeded, the complete original text for that transcription
is kept and an error is shown.

Rules stay on this Mac, alongside local history. Copy `corrections.json` to
the same location on another Mac to use the same rules there; there is no
automatic sync. Personal rules, audio, and transcripts are not included in
the repository or sent to a service.
