# frozen_string_literal: true

require "rake/testtask"
require "bundler/gem_tasks"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test

# The version lives in one place, lib/agents_control/version.rb, but the
# Claude Code plugin manifests carry their own copy — Claude Code reads
# them directly and never sees the gemspec. A one-line regex substitution
# rather than a full JSON rewrite: it leaves the rest of each file's
# formatting untouched, so a version bump doesn't produce a noisy diff.
MANIFESTS = [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json"].freeze

# The body of one version's entry, without its own heading — gh adds
# the title separately. Falls back to a pointer rather than failing the
# release over a missing entry, but says so loudly enough to notice.
def changelog_section(version)
  body = File.read("CHANGELOG.md")[/^## #{Regexp.escape(version)}\b.*?\n(.*?)(?=\n## |\z)/m, 1]
  return body.strip unless body.to_s.strip.empty?

  warn("no CHANGELOG entry for #{version} — the release will point at the file instead")
  "See [CHANGELOG.md](CHANGELOG.md)."
end

namespace :version do
  desc "Sync the Claude Code plugin manifests to lib/agents_control/version.rb"
  task :sync do
    require_relative "lib/agents_control/version"
    version = AgentsControl::VERSION

    MANIFESTS.each do |path|
      content = File.read(path)
      updated = content.sub(/"version":\s*"[^"]*"/) { %("version": "#{version}") }
      next if updated == content

      File.write(path, updated)
      puts "updated #{path} -> #{version}"
    end
  end
end

desc "Full release: tests, sync plugin manifests, tag/push/build/publish the gem, " \
     "cut a GitHub release, tag the plugin for Claude Code's own marketplace tooling"
task ship: [:test, "version:sync"] do
  sh "claude", "plugin", "validate", ".", "--strict"

  Rake::Task["release"].invoke

  require_relative "lib/agents_control/version"
  version = AgentsControl::VERSION

  # The release carries the changelog entry, not a list of commit
  # subjects: someone deciding whether to upgrade needs to read what
  # changed, and "Bump version to 0.3.0" tells them nothing.
  notes = File.join("pkg", "release-notes-#{version}.md")
  File.write(notes, changelog_section(version))

  sh "gh", "release", "create", "v#{version}", "--title", "v#{version}", "--notes-file", notes
  sh "claude", "plugin", "tag", ".", "--push", "-m", "agents-control %s"
end
