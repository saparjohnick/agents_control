# Changelog

Newest first. While the major is 0, a minor bump may change behaviour —
entries say so where it does.

## 0.3.0 — 2026-09-11

### Changed

- **`/run` now holds back a few destructive commands.** A recursive
  force delete aimed at `/` or `$HOME`, a fork bomb, `mkfs`, `dd` to a
  raw device. They come back naming what they do, and one tap sends
  anyway.
- Nothing else is affected: `rm -rf /tmp/build`, `cat .env` and
  `git push --force` go straight through. A seatbelt against the wrong
  tab number, not a filter — `bash -c 'rm -rf ~'` is not caught.

### Added

- **Optional passphrase** for those commands, instead of a tap.
  `agents_control passphrase set|clear|status`, offered during `setup`
  and from the bot itself.
  - PBKDF2-HMAC-SHA256, 210k iterations, salted; Keychain or libsecret;
    never argv.
  - The message carrying it is deleted from the chat once read.
  - Set from the chat, it guards against whoever reaches that chat
    later, not whoever has it now.
- **Files can be sent to a session** — photos, video, voice, documents.
  - Saved to `~/.local/state/agents_control/inbox/`; the pane gets the
    local path, never a link (the download URL contains the bot token).
  - Target: caption `/run N …`, or reply with the file to a session's
    message. Otherwise the path just comes back in the chat.
  - Kept `telegram.inbox_keep_days` (14), then swept.
- `/status`, `/settings` and `doctor` report whether a passphrase is set.

### Fixed

- **No panes were listed on tmux 3.5** — Debian 13's and Ubuntu
  24.10's. It prints the record separators as octal escapes where 3.7
  emits the bytes, so the parse found nothing and `/tabs` came back
  empty with no error.
- **The startup hook check probed whichever hook was listed first** —
  ours only until you have a `Stop` hook of your own. It replayed that
  entry's headers to its URL without TLS, sending a third party's
  bearer token in cleartext once per daemon start. Found by its marker
  now, and only probed on loopback.

### Internal

- The suite runs on Linux (554 tests, both platforms). It was green on
  macOS and 88 failures deep on Linux, which is how the tmux bug above
  survived a release.
- The suite fails if a test is written where Minitest won't collect it.

## 0.2.3 — 2026-09-04

- Menus whose options span several lines reach Telegram as buttons.
- A pager is caught by what's on screen, not only by its name.

## 0.2.2 — 2026-09-01

- Confirm before sending text into a pager, editor or REPL — a tab
  inside `less` reads a command as keystrokes and nothing runs.

## 0.2.1 — 2026-09-01

- `/run` against an agent confirms the send instead of dumping the
  transcript.

## 0.2.0 — 2026-09-01

- `/run` shows the command's actual result, anchored on the echoed
  command rather than a screen diff.

## 0.1.1 — 2026-09-01

- Name Claude Code explicitly wherever a feature is Claude-only.

## 0.1.0 — 2026-08-31

First release. Tab list, commands, screen and new sessions from
Telegram; for Claude Code, its questions and permission requests as
buttons, AskUserQuestion with one button per option.
