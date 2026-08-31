# frozen_string_literal: true

require_relative "lib/agents_control/version"

Gem::Specification.new do |spec|
  spec.name        = "agents_control"
  spec.version     = AgentsControl::VERSION
  spec.authors     = ["Sapar Kurmanov"]

  spec.summary     = "Control terminal AI agents (Claude Code, Codex) from Telegram"
  spec.description = <<~TEXT
    A daemon that catches the moments Claude Code stops and waits on a
    human, and relays them to Telegram — with the question's text and
    reply buttons. Plus a remote for the terminal itself: list tabs, create
    them, send commands.
  TEXT
  spec.homepage    = "https://github.com/saparjohnick/agents_control"
  spec.license     = "Apache-2.0"

  spec.metadata = {
    "source_code_uri" => "https://github.com/saparjohnick/agents_control",
    "bug_tracker_uri" => "https://github.com/saparjohnick/agents_control/issues",
    "documentation_uri" => "https://github.com/saparjohnick/agents_control/blob/main/README.md",
    "changelog_uri" => "https://github.com/saparjohnick/agents_control/releases",
    "rubygems_mfa_required" => "true"
  }

  spec.required_ruby_version = ">= 3.1"

  # git ls-files is deliberately not used here: the gem must build even
  # in a fresh directory with no commits.
  spec.files = Dir.glob("{lib,exe}/**/*", File::FNM_DOTMATCH)
                  .select { |f| File.file?(f) } +
               %w[README.md LICENSE].select { |f| File.exist?(f) }

  spec.bindir      = "exe"
  spec.executables = ["agents_control"]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.3"
end
