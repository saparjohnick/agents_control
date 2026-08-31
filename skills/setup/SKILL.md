---
name: agents-control-setup
description: Use when the user wants Telegram notifications or remote control for this (or another) terminal AI agent session — helps install and configure agents_control.
---

agents_control is a Ruby daemon that watches Claude Code sessions (via
hooks, plus a screen watcher for local CLI menus) and relays stops,
questions, and permission requests to Telegram, with buttons to reply
from the phone. It also gives a remote to the terminal itself: list
tabs, send commands, create sessions. Repo:
https://github.com/saparjohnick/agents_control

Runs entirely on the user's own machine, talking to a Telegram bot the
user creates themselves — no shared service, no data leaves the machine
except through that bot. The daemon's hook port only ever binds to
127.0.0.1, and it reaches Telegram via long-polling (outbound only, no
inbound port opened for that either).

## Helping the user set it up

1. Confirm Ruby 3.1+ is available: `ruby -v`. Terminal control needs
   iTerm2 or tmux on macOS, or tmux on Linux — Terminal.app alone isn't
   supported for that part, though notifications work regardless since
   they go through hooks, not the terminal.
2. Clone and install:
   ```sh
   git clone https://github.com/saparjohnick/agents_control
   cd agents_control
   bundle install
   ```
3. Have the user create a bot via [@BotFather](https://t.me/BotFather)
   on Telegram, then run `agents_control setup` **themselves, in their
   own terminal** — it prompts for the bot token without echoing it and
   waits for their `/start` message to catch the chat_id automatically.
   Don't run this inside a tool call: it needs a real interactive
   terminal and a live round-trip with Telegram.
4. After setup, `agents_control` with no arguments opens the always-on
   console — that's the normal way to run it. `agents_control doctor`
   checks that everything is wired up correctly.

Full command reference, the two operating modes (at-the-keyboard vs.
away), and the security model are in the project README.
