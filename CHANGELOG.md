# Changelog

Notable changes, newest first. Versions follow [semantic
versioning](https://semver.org): while the major is 0, a minor bump may
change behaviour, and the entry says so where it does.

## 0.3.0 — unreleased

### Destructive commands from Telegram now ask first

**This changes what `/run` does.** A handful of commands are held back
when they arrive from the bot: a recursive force delete aimed at `/` or
`$HOME`, a fork bomb, `mkfs`, `dd` writing to a raw device. They come
back with what the command actually does — "this recursively deletes
`~` — there is no undo" — and one tap sends it anyway.

Nothing else is affected. `rm -rf /tmp/build` goes straight through, as
do `cat .env` and `git push --force`: the bar is catastrophic and
irreversible, not merely sensitive, because a list that stops an
ordinary afternoon trains people to tap past it without reading. This
is a seatbelt against a thumb on the wrong line of a tab listing, not a
policy engine — `bash -c 'rm -rf ~'` is not caught, by design.

### An optional passphrase for those commands

A tap answers "did you mean this?". It does not answer "are you you?" —
an unlocked phone in someone else's hand taps just as well as its
owner. Set a passphrase and destructive commands ask for it instead of
a button:

```sh
agents_control passphrase set      # or during `agents_control setup`
```

It can also be set from the bot, at the moment a destructive command
turns up. Set that way it guards against whoever reaches the chat
*later*, not whoever has it now; the bot says so when it saves.

Stored derived (PBKDF2-HMAC-SHA256, 210k iterations, salted per write)
in the Keychain or libsecret, never as itself, and never accepted as a
command-line argument. The message carrying it is deleted from the chat
as soon as it is read, right or wrong, since chat history syncs to
every device the account is signed in on. `agents_control passphrase
clear` goes back to the button.

### Files can be sent to a session

Photos, videos, voice notes and documents — a log, a CSV, a screenshot
— can be sent to the bot and handed to an agent. The file lands in
`~/.local/state/agents_control/inbox/` and what reaches the pane is its
local path, so the agent opens it like anything else.

Caption it `/run N …` for a particular tab, or reply with it to a
session's own message. With nothing to go on the path just comes back
in the chat, because guessing a target is how a file ends up pasted
into the wrong project.

A path and never a link: Telegram serves file bytes from
`/file/bot<TOKEN>/…`, so the download URL *is* the bot token, and
handing that to an agent would put it in the terminal and the shell
history. Files are kept for `telegram.inbox_keep_days` (14) and then
swept.

### Fixed

- **The tmux backend saw no panes on tmux 3.5** — Debian 13's version
  and Ubuntu 24.10's. Pane records are separated by non-printable
  bytes; tmux 3.7 emits them and 3.5 prints their octal escapes
  instead, so the parse found nothing. `/tabs` came back empty with no
  error to explain it. Both forms are read now.
- **The startup hook self-check probed whichever hook was listed
  first**, which is ours only until the user has a `Stop` hook of their
  own. It replays that entry's headers to that entry's URL, and did so
  without TLS — sending a third party's bearer token in cleartext, once
  per daemon start. Ours is found by its marker now, and only probed on
  loopback.

## 0.2.3 — 2026-09-04

- Recognize menus whose options span several lines, so a skill's own
  wizard reaches Telegram as buttons rather than not at all.
- Catch a pager by what is on screen, not only by its name: a bare `:`
  as the whole last line is the one thing every pager agrees on.

## 0.2.2 — 2026-09-01

- Confirm before sending text into a pager, editor or REPL. A tab left
  inside `less` reads a command as keystrokes, and nothing runs.

## 0.2.1 — 2026-09-01

- `/run` against an agent confirms the send instead of dumping the
  whole transcript. An agent is not a command that finishes in a
  second, so there is no result to capture yet.

## 0.2.0 — 2026-09-01

- `/run` shows the command's actual result. The command itself is the
  anchor — the shell echoes it back — which survives other output
  arriving in the same tab.

## 0.1.1 — 2026-09-01

- Name Claude Code explicitly wherever a feature is Claude-only.

## 0.1.0 — 2026-08-31

First release. Terminal control from Telegram — tab list, commands,
screen, new sessions — and, for Claude Code, its questions and
permission requests relayed as buttons. AskUserQuestion answered with
real buttons per option.
