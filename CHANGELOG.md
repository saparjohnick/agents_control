# Changelog

Newest first. While the major is 0, a minor bump may change behaviour —
entries say so where it does.

## 0.4.1 — 2026-10-14

### Fixed

- **A photo or file sent without a reply now goes to the session that
  spoke last**, the same as text does since 0.4.0. It was only saved,
  and the path handed back, so it had to be sent again as a reply. The
  caption goes with it, and so does the rest of an album. Photos, video,
  audio, voice messages, video notes and animations are all covered.
  Only an agent receives it: a bare path typed into a shell is a
  command, not a file handed over, so a shell still just gets the file
  saved.

## 0.4.0 — 2026-10-10

### Changed

- **Text sent without a reply now goes to the session that spoke
  last.** Until now it got "I don't know that command". The last
  session is whichever one the bot most recently sent a message about
  — a notification, `/screen`, `/context` — and the text is handled
  exactly as a reply to that message would be. A reply still wins over
  it, and commands (`/…`) are never typed into a session. If that
  session is a plain shell, the text is typed into the shell.

### Fixed

- **A tab's agent was missed by a daemon that had been running a
  while.** The per-tab view of the process list was never refreshed, so
  an agent started after the daemon did showed as a plain shell
  in `/tabs`.
- **An agent was shown as a plain shell once Claude Code renamed its
  own process** to `Claude` partway through a long session.
- **A reply to an agent that had `cd`'d into a subfolder found no
  tab.** The nearest agent in a directory above is now taken to be the
  same one; a plain shell up there never is.
- **A dropped network lost what it carried.** A notification that hit
  an outage is retried in the background for about a quarter of an
  hour, a file from the phone is downloaded again a few times before it
  is reported, and the poller's pause after a network error now tops
  out at 10 seconds instead of a minute.
- **The rest of an album now follows its first file** to the agent it
  was sent to, instead of only being saved. Never into a shell.
- **The daemon's log lines no longer land on top of the line being
  typed** in the console.

## 0.3.1 — 2026-09-11

### Fixed

- **The daemon went permanently deaf on a routine network error.**
  Network failures were translated into a retry by matching a
  hand-written list of `Errno` constants. `EADDRNOTAVAIL` — what a VPN
  reconnecting produces — wasn't on it, so it escaped every rescue and
  killed the polling thread. The process stayed up, the hook port kept
  answering, agent events kept arriving, and nothing from Telegram ever
  did again. The list is now the whole `SystemCallError` family, and a
  backstop catches anything still unaccounted for.

### Added

- **`doctor` reports whether the daemon is still listening**, not just
  whether it's running — the hook port answers the same either way, so
  a dead poller was indistinguishable from a healthy one. A successful
  poll leaves a timestamp; `doctor` reads it and says how long ago.

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
