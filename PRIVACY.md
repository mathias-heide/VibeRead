# Privacy

Vibe Read is local-first, but dictation and optional text transformations are
not offline unless the user configures a compatible service on the Mac. This
document describes the current app's data flow.

## Stored on the Mac

- Transcript history is stored in a SQLite database under the user's
  Application Support directory and remains until the user deletes it. Each
  successful row stores the provider transcript and the final text used by the
  app. They are identical for normal dictation. Smart Dictation can change the
  final text.
- Dictation recordings are stored beside that database and deleted after seven
  days by default. The user can choose immediate, one-day, seven-day, 30-day,
  or indefinite retention.
- Saved text, extracted pages, summaries, and bookmarks are stored in
  `library.json` under the same local Application Support directory.
- Screenshots of areas marked with Ctrl during dictation are written as PNG
  files to the macOS temporary folder, so the clipboard fallback and history
  can reference them by path. Files older than a day are deleted the next time
  marks are used, and macOS also clears that folder. The history text for such
  a dictation contains those file paths.
- Shortcuts, provider choices, provider URL and model identifiers, dictation
  language, vocabulary, retention choice, Smart Dictation prompt, and
  user-defined action prompts are stored in macOS preferences. The selected
  ElevenLabs voice, cached voice metadata, and the editable voice preview
  phrase can also be stored there.
- API keys can remain in a user-selected `.env` file. Pasted or recovered keys
  are stored in macOS Keychain. Groq, OpenRouter, and OpenAI each use one
  provider credential that can power dictation, Smart Dictation, and Cmd + E.
  ElevenLabs uses one credential for dictation and optional read-aloud. Custom
  dictation and custom text actions use separate credentials.
- When automatic paste is enabled, Vibe Read temporarily stages completed text
  on the macOS clipboard, posts Cmd + V, and restores the previous clipboard.
  If Vibe Read knows the paste failed, it fills an empty clipboard directly.
  It asks before replacing an occupied clipboard. Escape, Keep, timeout, or a
  clipboard change preserve the existing contents. macOS Universal Clipboard
  settings may sync temporary or confirmed clipboard contents through services
  controlled by the user.

Launching Vibe Read and opening Settings do not read Keychain. The app reads a
saved Keychain item only after the user explicitly verifies it or intentionally
uses that provider. A Keychain key is cached in memory until the app quits. A
selected `.env` value is read from that file when used. Older generic provider keys are not automatically discovered or
migrated.

Credential setup is always user initiated. **Use Existing Key** can remember a
`.env` file the user selects and read only one named provider variable when the
provider is used, or attempt a
noninteractive read from the previous Vibe Read build. Recovery is forbidden
from displaying a macOS password prompt. A `.env` key is not copied into
Keychain. Vibe Read does not scan the disk for environment files.

The database and recordings are not application-level encrypted. macOS account
security restricts access, and users can enable FileVault for encryption at
rest.

## Sent over the network

Vibe Read contacts a configured provider when the user finishes dictation,
runs a provider-backed text action, explicitly loads or previews an ElevenLabs
voice, asks for ElevenLabs read-aloud, or asks the app to verify provider
access.

### Dictation

Recorded audio goes directly from the Mac to the selected dictation provider:

- ElevenLabs dictation sends recorded audio to
  `https://api.elevenlabs.io/v1/speech-to-text` with the Scribe v2 model.
- Groq dictation sends recorded audio to Groq's OpenAI-compatible
  `/audio/transcriptions` endpoint.
- OpenRouter dictation sends recorded audio to OpenRouter's
  `/audio/transcriptions` endpoint. OpenRouter can route the request to an
  upstream model provider.
- OpenAI dictation sends recorded audio to OpenAI's
  `/audio/transcriptions` endpoint.
- Custom dictation sends recorded audio to `/audio/transcriptions` under the
  endpoint configured by the user.

These requests include the selected model where applicable and may include an
explicit language. Vocabulary can also be included for providers that support
the app's prompt field. The raw transcript returned by the provider is stored
locally.

When areas of the screen were marked with Ctrl during a dictation, the same
request also asks for word timestamps (ElevenLabs, Groq, and OpenAI
`whisper-1`) so screenshots can be placed where they were spoken. Screenshots
themselves are never sent to any provider. They are only pasted into the app
that has the cursor.

### Text processing

Normal Fn dictation does not contact the configured text provider. It uses the
raw transcript returned by the dictation provider.

Smart Dictation is a separate mode with a separate shortcut. It first uses the
configured dictation provider, then sends the raw transcript, the locally
stored Smart Dictation prompt, and the sanitized name of the app where
dictation began to the configured text provider. The app name is limited to 80
characters and control characters are removed. This request does not include
selected text, window titles, document contents, screenshots, or other screen
context. If editing fails, Vibe Read keeps and uses the raw transcript instead
of discarding a successful dictation.

A provider-backed Cmd + E action sends the selected text, action prompt, and
selected model to the text provider configured for Cmd + E. Its response
appears in the action palette for review. The user can copy, discard, or apply
it explicitly.

Text providers are OpenRouter, Groq, OpenAI, or a custom OpenAI-compatible
endpoint. These requests use the provider's `/chat/completions` endpoint.

### Verification

For Groq, OpenRouter, OpenAI, and custom providers, **Save and Verify** sends an
authenticated request to a provider model-list endpoint. It does not upload
dictation audio, selected text, or an action prompt. A successful verification
checks access to that endpoint. It does not guarantee that every selected model
is available to the account. ElevenLabs uses **Save Key** without a network
request. Its first dictation is the Scribe v2 end-to-end test.

These calls go directly from the Mac to that endpoint. The provider may log,
retain, or use submitted data according to its own policy. Users should choose
a provider and models appropriate for the sensitivity of their material. When
an aggregator routes to another company, users should review the policies and
settings of both services.

ElevenLabs enables request logging by default for standard API usage. Its zero
retention mode is a provider-side enterprise feature. Vibe Read does not claim
or enable provider-side zero retention. Review the provider settings and policy
that apply to your account.

The app's provider client disables URL caching and cookies for these requests.
This does not control what a provider retains after receiving a request.

Read-aloud uses the macOS speech synthesizer locally by default. When the user
selects ElevenLabs read-aloud and presses Read or Preview, the chosen reading
text or entered preview phrase is sent directly to ElevenLabs and generated
audio is returned to the Mac. These requests count toward the user's provider
usage. Choosing Load Voices makes a direct authenticated voice-list request but
does not send reading text. Returned voice metadata may be cached in macOS
preferences, and searching the voice list is local.

Saving or reading a copied web address fetches that page directly from the
Mac. YouTube support requests public metadata and captions. Vibe Read does not
use AppleScript, browser automation, or a Vibe Read proxy for these workflows.
Copying, pasting, opening the action palette, and adding, editing, or deleting
action definitions do not by themselves send a network request.

## Not included

The current app includes no:

- Vibe Read account or authentication
- Vibe Read cloud database, storage, or sync
- subscription or payment flow
- product analytics or tracking SDK
- automatic crash-reporting service
- operated API proxy or relay
- hosted auto-update service

In particular, the local-only application does not use Supabase, PostHog, or
Stripe.

## Permissions

Vibe Read does not show system permission prompts at startup. macOS access is
requested only after the user clicks Grant Access or intentionally uses a
feature that needs it.

- **Microphone:** records audio only after the user starts dictation.
- **Accessibility:** observes function-key shortcuts, reads selected text, and
  inserts text into other applications. Ordinary global chords such as Cmd + E
  do not require this permission.
- **Screen Recording:** takes a screenshot of an area only when the user marks
  it with Ctrl during a dictation. Requested from Settings together with
  Accessibility, or the first time a mark is made.
- **Clipboard:** temporarily stages automatic paste text and marked
  screenshots, supports explicit copy actions, and provides a confirmed
  fallback after known paste failures.

Selected text used by an action is held in memory for the operation and is not
added to dictation history.

## Control and deletion

Users can delete individual dictations, all retained audio, or all history and
audio from the app. Provider keys can be removed separately in AI Provider
settings. See [LOCAL_DATA.md](LOCAL_DATA.md) for paths, backup instructions,
and complete removal steps. A generic provider item created by an older build
is never automatically discovered or removed and may need to be deleted
manually in Keychain Access.

Removing local data does not delete information already submitted to a chosen
provider. Use that provider's controls for its copies.
