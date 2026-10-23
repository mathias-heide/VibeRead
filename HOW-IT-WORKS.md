# How Vibe Read works

Vibe Read is a local-first macOS app for dictation, read-aloud, and
configurable text actions. Local-first describes storage, not speech
processing. Unless a compatible service is running on the Mac, dictation audio
leaves the Mac for the provider selected by the user.

## Provider setup

For the normal ElevenLabs setup, open Vibe Read, paste the key under
**Settings > Providers**, click **Save Key**, and close Settings. Press **Fn**
once to start dictating and press **Fn** again to send. Nothing else is needed.

An existing key does not need to be recreated. **Use Existing Key** can use
`ELEVENLABS_API_KEY` from a chosen `.env` file without copying the key into
Keychain, or explicitly recover the key from the previous Vibe Read build.
Recovery is noninteractive and never opens a macOS password prompt.

The other provider and model controls are optional. They exist for people who
want Groq, OpenRouter, OpenAI, or a compatible service running locally.

Dictation and text processing are configured independently. Normal Fn
dictation uses only the dictation provider. Smart Dictation and
provider-backed Cmd + E actions use the text provider.

| Feature | Built-in choices | What can be selected |
| --- | --- | --- |
| Dictation | ElevenLabs, Groq, OpenRouter, OpenAI, Custom OpenAI-compatible | Provider, transcription model where supported, and language or auto detect |
| Smart Dictation and Cmd + E | OpenRouter, Groq, OpenAI, Custom OpenAI-compatible | Provider and text model |

Each provider credential can stay in a user-selected `.env` file or be saved
in macOS Keychain. If Groq, OpenRouter, or OpenAI is selected for both dictation
and text processing, both features use that provider's credential. ElevenLabs can power both Scribe
dictation and optional ElevenLabs read-aloud. Custom
dictation and custom text actions have separate endpoint URLs and credentials.
Provider choices, model identifiers, language, `.env` file paths, and custom endpoint URLs
are non-secret preferences stored by macOS.

Launching Vibe Read and opening Settings do not read Keychain or a selected
`.env` file. The app reads a credential only after the user explicitly verifies
it or intentionally uses that provider for dictation, Smart Dictation, or a text action.
Keychain values are cached in memory until the app quits. Older generic provider keys
are not automatically discovered or migrated. Users must re-enter an older key
for the provider they want to use and choose its explicit save action.

A remote custom endpoint must use HTTPS. An HTTP endpoint is accepted only for
loopback addresses such as `127.0.0.1` or `localhost`. A loopback service may be
configured without an API key.

## Dictation

1. A global shortcut starts a microphone recording.
2. When recording stops, Vibe Read sends that audio directly from the Mac to
   the dictation provider selected in Settings.
3. The provider returns a raw transcript.
4. Normal Fn dictation uses that transcript as-is. It does not call the text
   provider.
5. Smart Dictation, started with Fn + Option by default, sends the raw
   transcript to the configured text provider together with the locally stored
   Smart prompt and a sanitized name of the app where recording began. The app
   name is limited to 80 characters and control characters are removed. Vibe
   Read does not send selected text, window titles, documents, screenshots, or
   screen contents with this request.
6. If the Smart edit succeeds, its response becomes the final text. If it
   fails, Vibe Read keeps the successful raw transcript as the final text and
   reports a nonfatal warning.
7. Vibe Read saves the raw transcript and final text to a local SQLite
   database. The app containing the cursor when Send is pressed becomes the
   delivery target. Vibe Read rechecks that target before posting Cmd + V and
   restores the previous clipboard after the paste attempt. If a known paste
   failure needs a clipboard fallback, an empty clipboard is filled directly.
   An occupied clipboard is replaced only after the user confirms with Return
   or the Copy button. Escape, Keep, and timeout preserve it.
8. The retained recording is stored under Application Support. Audio is
   deleted after seven days by default. Transcript text remains until the user
   deletes it.

There is no Vibe Read server, account, or cloud database between the app and
the configured providers.

## Marking the screen while dictating

While a normal Fn dictation is recording, hold Ctrl and move the mouse over
something. No click is needed. Releasing Ctrl takes a screenshot of the area
the pointer covered, and a numbered red outline briefly shows what was captured,
fading out within half a second. The marks are click-through, so the app underneath keeps
working. Vibe Read leaves itself out of the screenshot. Ctrl combined with a
key, such as Ctrl + C, or with another modifier is not treated as a mark.

The whole recording is transcribed in one request, so it is fine to keep
talking while you mark. Vibe Read asks the provider for word timestamps
(ElevenLabs, Groq, and OpenAI `whisper-1`). For other providers it estimates
timing from each word's position in the transcript. Each image is placed at
the moment you released Ctrl. Released during a pause, it goes into that
pause. Released while talking, it goes into the nearest gap between words, or
after a comma or full stop if one is less than a second away.

Vibe Read then pastes the text and screenshots in order into the app that has
the cursor. Terminal apps such as Claude Code get images with Ctrl + V. Other
apps get Cmd + V. Your previous clipboard is restored afterwards. Screenshots
are never sent to a provider. They are kept in the temporary folder for up to
a day so the clipboard fallback and History can reference them by path.

## Read-aloud

Read-aloud has two explicit modes. The macOS mode uses `AVSpeechSynthesizer`
and keeps text on the Mac. The ElevenLabs mode sends only the text the user
chooses to read directly to ElevenLabs, downloads generated audio, and plays it
locally. **Load Voices** is an explicit authenticated request. Its voice
metadata may be cached in macOS preferences so the picker can reopen without a
background request. Search runs on that local list. Preview sends the phrase
entered in Settings to ElevenLabs and uses provider credits, just like normal
ElevenLabs read-aloud. Voice loading, preview, and reading are the only times
read-aloud accesses the ElevenLabs credential.

## Text actions

The action palette opens over selected text with Cmd + E by default. Local
actions such as Copy and Read aloud do not make network requests. User-editable
rewrite actions send the action prompt and selected text directly to the text
provider configured for Cmd + E. The result stays in the palette for review.
The user can copy it, cancel it, or explicitly apply it. The text provider is
optional, so local actions remain available without one.

The Actions screen provides an in-app sheet for adding, editing, and deleting
custom actions. It validates the name and prompt before saving. Action
definitions and shortcuts are stored in macOS preferences. When Vibe Read loads
actions created by an older version, it removes exact name-and-prompt
duplicates while preserving the first copy and its order. Selected text is not
added to dictation history.

When the current selection or clipboard contains a web address, Cmd + E can
extract a readable article or Wikipedia page, or use public YouTube captions.
It does not automate the browser or request Apple Events access. Save to
Library writes the extracted text or link to `library.json` under the local
Application Support directory.

## Storage and network boundary

```text
Normal Fn:
Microphone -> selected dictation provider -> raw transcript -> local SQLite

Smart Fn + Option:
Microphone -> dictation provider -> raw transcript + local Smart prompt
                                      + sanitized target app name
                                   -> text provider -> local SQLite

Selected text -> optional Cmd + E text provider -> preview -> explicit apply
Text to read  -> macOS speech synthesizer or chosen ElevenLabs voice
Copied URL    -> direct page fetch -> local Library
```

The current app has no account system, subscriptions, analytics, cloud
database, cloud storage, or sync. See [PRIVACY.md](PRIVACY.md) and
[LOCAL_DATA.md](LOCAL_DATA.md) for the precise data boundary.

## Permissions

Vibe Read does not request system access at startup. A macOS permission prompt
appears only after the user clicks Grant Access or intentionally uses a feature
that needs the permission.

- **Microphone** is required for dictation.
- **Screen Recording** is required only for marking the screen while
  dictating. Request Access in Settings asks for it together with
  Accessibility, and it is also requested the first time you mark something.
- **Accessibility** is required for function-key shortcuts, reading selected
  text, and inserting text into other apps. Ordinary global chords such as
  Cmd + E do not require it.
- **Clipboard** access is used by explicit copy actions and can be offered as a
  fallback when an app does not expose selected text through Accessibility.

The Read view can still speak text pasted into the app without Accessibility
permission.
