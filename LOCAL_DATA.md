# Local data and migration

Vibe Read stores its own data on the Mac. Nothing in this directory is synced
by Vibe Read.

## Data locations

The main data directory is:

```text
~/Library/Application Support/VibeRead/
├── dictations.sqlite3
├── dictations.sqlite3-wal      # may exist while the app is running
├── dictations.sqlite3-shm      # may exist while the app is running
├── library.json               # saved text, pages, summaries, and links
└── Dictations/
    └── … retained audio files
```

- `dictations.sqlite3` contains the provider transcript, the final text used by
  Vibe Read, timestamps, duration, and relative references to retained
  recordings. The two text values are identical for normal dictation. Smart
  Dictation can produce a different final value.
- `Dictations/` contains recordings that are still inside the chosen retention
  window.
- `library.json` contains items saved to the local Library. Delete individual
  items in Library or use **Settings → Local Data → Delete Saved Library**.
- Preferences such as shortcuts, action definitions, Smart Dictation prompt,
  dictation and text provider choices, model identifiers, language, custom
  provider URLs, retention settings, selected read-aloud voice, cached
  ElevenLabs voice metadata, and the editable voice preview phrase use the
  standard macOS preferences system.
- API keys are generic-password items in macOS Keychain. Groq, OpenRouter, and
  OpenAI each use one provider item that can power dictation, Smart Dictation,
  and Cmd + E. ElevenLabs uses one item for dictation and optional read-aloud.
  Custom dictation and custom text actions use separate items. Keys are not
  stored in SQLite or preferences.

Screenshots of areas marked with Ctrl during dictation are written to
`$TMPDIR/VibeRead/VisualCaptures/` so a clipboard fallback or history entry can
reference them by path. Files older than a day are removed the next time marks
are used, and macOS clears the temporary folder on its own schedule.

The SQLite database is not application-level encrypted. Use FileVault and a
locked macOS account if local-at-rest protection matters for your threat model.

## Retention

Transcript history has no automatic expiration. Delete an individual entry or
use **Settings → Local Data → Delete All History and Audio** to remove it.

Audio is deleted after seven days by default. The choices are immediately,
after one day, after seven days, after 30 days, or never. Cleanup runs when the
store starts, after each dictation, when the setting changes, and once a day
while the app remains open.

When **Immediately** is selected, Vibe Read removes the audio as soon as the
store records the result. This applies to successful and failed dictations.
The transcript row can remain, but a failed dictation without audio cannot be
retried.

Use **Delete All Audio** to remove recordings while preserving transcript text.

## Back up or move local data

1. Quit Vibe Read so SQLite can finish its write-ahead log.
2. Copy the entire `~/Library/Application Support/VibeRead/` directory.
3. Restore that directory to the same location while Vibe Read is not running.

Copy the whole directory rather than only the `.sqlite3` file. Provider keys
are not included. Configure them again on the destination Mac. Non-secret
provider, model, language, shortcut, and retention preferences are also outside
this directory and may need to be configured again.

## Migration from earlier local builds

Earlier builds stored dictation history as JSON values in macOS preferences,
with unscoped or account-scoped keys, and placed audio either directly inside
the Dictations directory or in a nested directory.

On first launch, the local-only store automatically:

1. discovers all recognized legacy dictation-history preference values;
2. normalizes safe audio paths into the current Dictations directory layout;
3. imports all decoded rows into SQLite in a transaction; and
4. removes each legacy preference value only after SQLite confirms the import.

The import is idempotent. If decoding or persistence fails, the source value is
left in place for recovery. Transcript contents are not printed during the
migration. This history migration scans local files and macOS preferences. It
does not access Keychain.

New recordings are WAV or M4A and can be retried with every built-in provider.
Some older imported formats are not portable between provider APIs. CAF, AIF,
and AIFF retries are rejected for hosted providers. AAC is rejected for Groq
and OpenAI, while MP4 is rejected for OpenRouter. Vibe Read reports the format
before sending a request and leaves the original local file unchanged.

Older builds could append the same placeholder custom action every time Add
Action was clicked. When the current app loads custom actions, it removes exact
duplicates with the same trimmed name and prompt. The first copy and the
remaining action order are preserved. New actions are saved only after the
in-app editor validates both fields. Actions can be edited or deleted from the
Actions screen.

Earlier builds could store one generic provider key in Keychain. Vibe Read does
not automatically discover or read that item. **Use Existing Key** can recover
the immediately previous Vibe Read key without allowing a password prompt, or
use the named provider variable from a `.env` file selected by the user. The
app remembers only the file path and does not copy that key into Keychain. This
release uses a new versioned Keychain namespace only for pasted or recovered keys.

Launching Vibe Read and opening Settings do not read Keychain. A saved key is
read only after explicit verification or an intentional provider request. Once
loaded, it is cached in memory until the app quits.

Vibe Read never searches for `.env` files. It reads only the provider variable
named in the picker, first to validate the selected file and later when that
provider is intentionally used.

This migration covers data already present on the Mac only. It does not connect
to or import from the former hosted database. Anyone who used a hosted Vibe Read
build should export any server-side data they want to retain before that service
is removed. Server-side export and deletion are operational tasks outside this
local app and repository.

## Removing all local data

Before uninstalling:

1. Use **Settings → AI Provider** to remove each saved provider key. Select
   each configured provider in turn if more than one has a saved key.
2. Use **Settings → Local Data → Delete All History and Audio**.
3. Use **Settings → Local Data → Delete Saved Library**.
4. Quit the app and remove `~/Library/Application Support/VibeRead/` if it still
   exists.

Other non-secret preferences may remain in the normal macOS preferences store.
An old generic provider item from a legacy build may also remain in Keychain
because Vibe Read never discovers or migrates it. Remove that item manually in
Keychain Access if you want to erase it.
