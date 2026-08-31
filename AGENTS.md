# AGENTS.md

## Setup

Ruby 3.1+. No native extensions to compile.

```sh
bundle install
```

## Build & test

```sh
rake test
```

Minitest, no mocking gems — hand-rolled `Fake*` doubles in
`test/test_helper.rb` (`FakeExecutor`, `FakeApi`, ...). External
commands (`osascript`, `tmux`, `ps`, `security`) are never actually
invoked in tests; `test/fixtures.rb` holds recorded real command
output used to build those fakes.

Run a single file: `ruby -Itest test/path/to/file_test.rb`.

## Code style

- Comments explain non-obvious *why* (an external system's quirk, a
  security constraint, a subtle invariant) — never restate what the
  code already says through naming. If removing a comment wouldn't
  confuse a reader, don't add it.
- No mocking frameworks. Test doubles are small, purpose-built classes.
- External I/O (shell commands, HTTP, filesystem) goes through
  `Executor`/`Which` so it's swappable in tests — don't shell out or
  hit the network directly from business logic.
- Secrets never touch argv, the config file, or git. See `secrets.rb`
  and the README's Security section before changing anything there.
- Fail-open: a daemon crash or a background watcher's error must never
  block the agent it's watching. Rescue broadly at watcher-loop
  boundaries; never let a `rescue` handler's own failure (e.g. a
  logging call) escape past it.

## Security notes

The daemon binds its hook server to `127.0.0.1` only and talks to
Telegram via long-polling (outbound only) — don't add anything that
listens on a non-loopback interface or opens an inbound port. Tokens
live in Keychain/libsecret via `Secrets`, never in `config.yml`, argv,
or logs.

## PR notes

One logical fix per commit, with a message explaining *why*, not just
what changed. Run `rake test` before committing — every behavior
change needs a test.
