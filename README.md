# agents_control

[![Gem Version](https://img.shields.io/gem/v/agents_control)](https://rubygems.org/gems/agents_control)

A remote for iTerm2 and its AI agents (Claude Code, Codex) from Telegram:
tab list, commands, screen, new sessions. For Claude Code — also the
agent's questions and permission requests: it stops, buttons show up in
Telegram, you answer, the session unblocks.

Everyone runs their own bot — the token lives in the Keychain or
libsecret, never in files or in git. The daemon is invisible from
outside: the port only binds to 127.0.0.1, there are no incoming connections.

> **Status:** terminal control and Claude Code work in full. Codex
> sessions are visible and controllable through the terminal (like any
> tab), but without the question relay: its hooks don't give us
> anything to hook into for that yet.

## Platforms and requirements

- **macOS** — terminal backend: iTerm2 (via AppleScript) or tmux;
  secrets: Keychain; autostart: launchd.
- **Linux** — terminal backend: tmux; secrets: libsecret; autostart: systemd.
- **Windows is not supported.**
- **Ruby 3.1+.** The only external dependency is `thor` (pure Ruby, no
  C extensions) — installing it compiles nothing.

On macOS, terminal control (sending commands, reading the screen,
creating tabs) works through iTerm2 or tmux — Terminal.app isn't
supported. Notifications about questions and permissions aren't tied to
a terminal at all: their source is Claude Code's hooks, which work
everywhere, including sessions with no terminal (a VS Code session, for
instance).

## Why

You need to run a command in a session, check the screen, or switch to
a tab, and you're not at the computer — now you can do that from
Telegram. If the session is Claude Code, there's a bonus too: it
stops and waits for an answer — the question and its buttons arrive in
Telegram, no need to go home just to say "continue."

## How it works

Hooks, not screen scraping. Claude Code itself calls agents_control
when it stops — the hook waits for an answer and passes the decision
back into the session. There's currently one adapter, for Claude Code;
a new agent needs a file with the same interface. Codex didn't fit:
its hooks only see shell commands and only understand `deny` — there's
no "agent stopped" event to hook into at all.

The terminal is iTerm2 or tmux, and each session picks its own backend.
Terminalless sessions (VS Code) are visible and answer hooks too — they
just have nothing to type into and nowhere to read a screen from.

## Installation

```sh
git clone https://github.com/saparjohnick/agents_control
cd agents_control
bundle install
```

Or as a RubyGem:

```sh
gem install agents_control
```

Or straight from Claude Code, as a plugin — the repo doubles as a marketplace:

```
/plugin marketplace add saparjohnick/agents_control
/plugin install agents-control@agents-control
```

The plugin doesn't replace the install above — it's just a way to find
the tool and get install instructions without leaving Claude Code.

## Telegram

Create a bot with [@BotFather](https://t.me/BotFather) and run the wizard:

```sh
agents_control setup    # asks for the token, waits for your /start
agents_control           # after that, just open the console
```

The wizard catches your `chat_id` from your own message and adds it to
the allowed list — no need to type in a long number by hand.

Bot commands:

| Command | What it does |
|---|---|
| `/agents` | sessions with a live agent |
| `/tabs` | all terminal tabs |
| `/screen N` | show a tab's screen |
| `/focus N` | switch to a tab |
| `/run N command` | run a command in a tab and show the result |
| `/new [directory]` | create a tab |
| `/away` | intercept agent questions |
| `/status` | current status |

The number `N` comes from the last list shown.

`/run` treats the command itself as the reference point: the shell
echoes back whatever's typed, so it looks for that exact text on
screen and shows from there — sharper than diffing screenshots, and
it still works even if something else wrote to the same tab in
between, since it doesn't need the screen from right before typing to
relate to the screen after at all. A short reply ("y", "n" mid `git
add -p`) isn't a safe anchor on its own — too likely to match
something unrelated — so those fall back to a before/after diff
instead, and when even that can't cleanly tell what's new, to the
current screen outright: seeing the result, possibly with a little
stale context around it, beats not seeing it at all. How much gets
captured either way is a `/settings` option (`terminal.run_result_lines`,
200 by default) — a command whose output runs longer just gets its
last N lines, same as the default gets cut by a screen that's too tall.

The result stays a live target: replying to it — "y", "n", anything —
types straight into that same pane and shows what came back, so
something like `git add -p`'s hunk-by-hunk prompts works as an actual
back-and-forth over Telegram, not a one-shot fire-and-forget.

Both `/run` and `/screen` head their reply with the tab's label and
tty (`valkyrie · ttys017`) — several tabs can share a label when
they're open on the same project, and the tty is what actually tells
them apart.

This list also populates Telegram's own `/` command menu automatically
— `setup` and every daemon start publish it via the Bot API, no manual
BotFather step needed. If the menu still shows only `/start` after
that, it's Telegram's client caching the old list, not a missing step
on your end: close and reopen the chat, or restart the Telegram app,
to force it to refresh.

### Two modes

This whole section is about Claude Code specifically — its hooks are
what makes any of it possible. While you're at the keyboard,
intercepting its questions is counterproductive: you'll answer in the
terminal faster than you can reach for your phone, and a blocked hook
keeps the dialog from ever appearing on screen. So there are two modes:

- **present** (default) — questions are mirrored to Telegram but stay
  in the terminal;
- **away** (`/away`) — a question arrives with buttons and waits for a
  reply; Claude Code stands by until you answer or time runs out.

A question can also be answered by replying directly to the message —
it goes to the right session, even with several tabs open.

Silence is treated as a refusal. If nobody answered while you were
out, the action doesn't happen, and the session just keeps waiting in the terminal.

AskUserQuestion is the one exception to all of this: its answer never
travels back through the hook at all, so there's nothing to block on —
it always arrives with real buttons for each option, in both modes.
Tapping one types that choice straight into the terminal, the same
keystroke you'd type by hand. An open-ended option ("something else,"
"explain what you mean") has no button — just reply to the message
with your own words instead. With more than one question in a single
batch, or several tabs sharing the same directory so the target pane
is ambiguous, buttons are skipped in favor of a plain reply, since
guessing at the terminal's exact sequencing there risks typing into
the wrong place.

A "continue" reply is sent automatically, but tool permissions aren't.
These are two independent settings on purpose: merged into one, they'd
let it approve itself everything while nobody's watching. A question
that offers a choice ("rewrite it or leave it?") is never answered
automatically, even if it contains the word "continue."

### Hooks

The daemon connects hooks on start and removes them on stop — otherwise
Claude Code prints a warning about an unreachable address in every
session. If the daemon crashed and the hooks are still there:

```sh
agents_control hooks          # check status
agents_control hooks uninstall
```

Entries in `~/.claude/settings.json` are tagged, and other settings
aren't touched: installing and removing return the file to exactly its original shape.

## Usage

```sh
agents_control          # opens the console and stays in the tab
```

The tool lives in a tab: while it's open, it listens to Telegram and
receives agent events. Commands inside start with a slash, same as the bot's:

```
> /sessions          sessions with a live agent
> /tabs              all terminal tabs
> /away              intercept agent questions (before stepping out)
> /settings          settings; /settings away — toggle
> /doctor            check that everything is in place
> /quit              quit
```

State icons: `⏳` working · `▸` at a shell prompt · `🖥` no terminal
(VS Code) · `·` everything else.

One-off commands exist too — `agents_control sessions`, `doctor`,
`daemon` — but the normal way to run it is an open console.

## Rate-limit anchors

A five-hour window starts at the minute of the first message and
expires exactly three hundred minutes later. An anchor doesn't add a
single extra token — it moves window boundaries to where they're
convenient: the difference between "the window reset at 2:37pm,
mid-work" and "windows at exactly 7am, noon, and 5pm."

The ping uses a **cheap model**, and that's not economizing for its own
sake. The five-hour window is shared across the account, but weekly
limits are tracked per model family: an anchor on opus would spend the
scarcest bucket for an effect haiku gives for free.

Turned on in `/settings`. If you were working recently and a window is
already open, the ping is skipped — the daemon sees every agent event
and knows this without polling anything.

On macOS, a 7am anchor won't fire if the laptop is asleep: `doctor`
catches this and suggests `pmset repeat wakeorpoweron`.

## Watchers

Hooks see Claude Code's own decisions, but not everything: the CLI's own
local menus (model switch, folder trust) and text on screen (a
rate-limit message) aren't covered by hooks at all — these events never
produce a single hook call. Two independent watchers handle them,
working over the screen rather than over Claude Code. Both go through
the full `Registry` — they see bare iTerm2 tabs and tmux panes alike.

**CLI menus** (`terminal.watch_menus`, on by default, polled every 20
seconds — `terminal.menu_poll_interval`). Notices the "❯ 1. … / 2. …"
pattern Claude Code uses to draw any choice, and sends it to Telegram
as buttons — pressing one types the option's number straight into the pane.

**Limit reset** (`answers.auto_resume_after_limit`, on by default,
polled once a minute — `terminal.rate_limit_poll_interval`). Notices a
message like "resets 3pm (UTC)" / "resets Oct 9, 10am" and types the
continuation itself once the time comes (with a minute of headroom).

## Checking and autostart

```sh
agents_control doctor           # is everything in place
agents_control service install  # autostart (launchd / systemd)
```

`doctor` checks **the environment the daemon will actually get**, not
the current one: an interactive shell can show a different Ruby and a
different PATH than the process a service manager launches separately
— for instance, if a Ruby version manager puts a broken shim on PATH
ahead of the working interpreter.

That's why the service always starts via an absolute path to the
interpreter, never through PATH.

## Why a tab's title can't be trusted

An agent sets a tab's title via an OSC sequence, and the title stays up
after it exits — a tab with an agent icon isn't necessarily still
running anything. That's why an agent's presence is confirmed by the
process tree, and the title is only ever used as a label.

## Security

This tool lets you run commands on your machine from Telegram. That comes with some rules:

- **There's no shared service.** Everyone sets up their own bot with
  @BotFather and connects it with their own token — the daemon talks to
  a bot only you own, not to any third-party infrastructure.
- **The daemon's port only listens on `127.0.0.1`.** Reaching it from
  outside the machine isn't just blocked by a password, it's physically
  impossible. The daemon talks to Telegram itself via long polling —
  outgoing connections only; no incoming port is opened for this either.
- **An allowed `chat_id` list is required.** While it's empty, the bot
  answers nobody, even if someone learns its name. The bot's token
  isn't an access secret; the access secret is the chat_id filter.
- **A leaked bot token is equivalent to remote code execution.**
- The token is stored in the Keychain (macOS) or libsecret (Linux) —
  the same place as website and Wi-Fi passwords — and never lands in
  the config. There's deliberately no command-line argument for the
  token: it would leak into `ps` and shell history.
- This protects against leaks through git, config files, `ps`, and
  shell history — not against malicious code already running as the
  same user: like any CLI tool without its own signed `.app`, the
  Keychain entry trusts the `security` utility itself, not
  agents_control specifically, so any process on the same account that
  knows the service name can read the token.
- Auto-replying "continue" is on by default; automatic tool approval is
  off. These are separate settings on purpose.

## Development

```sh
rake test
```

Tests run on minitest, with external commands stubbed via
`FakeExecutor` — neither iTerm2 nor tmux is needed to run them.
Fixtures live in `test/fixtures.rb` — recorded output from real commands.

## License

Apache 2.0.
