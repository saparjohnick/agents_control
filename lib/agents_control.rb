# frozen_string_literal: true

require "io/console"

# The base error is declared before the other files: error classes
# inherit from it right in a class body (the Telegram client, for
# example), and a class body runs at require time.
module AgentsControl
  class Error < StandardError; end
end

require_relative "agents_control/version"
require_relative "agents_control/executor"
require_relative "agents_control/which"
require_relative "agents_control/session"
require_relative "agents_control/process_probe"
require_relative "agents_control/terminals/base"
require_relative "agents_control/terminals/iterm2"
require_relative "agents_control/terminals/tmux"
require_relative "agents_control/terminals/null"
require_relative "agents_control/registry"
require_relative "agents_control/config"
require_relative "agents_control/store"
require_relative "agents_control/secrets"
require_relative "agents_control/event"
require_relative "agents_control/reply"
require_relative "agents_control/pending"
require_relative "agents_control/transcript"
require_relative "agents_control/agents/base"
require_relative "agents_control/agents/claude_code"
require_relative "agents_control/hooks/server"
require_relative "agents_control/dispatcher"
require_relative "agents_control/channels/base"
require_relative "agents_control/channels/telegram/markdown"
require_relative "agents_control/channels/telegram/chunker"
require_relative "agents_control/channels/telegram/api"
require_relative "agents_control/channels/telegram/keyboards"
require_relative "agents_control/channels/telegram/settings_menu"
require_relative "agents_control/channels/telegram/channel"
require_relative "agents_control/channels/telegram/router"
require_relative "agents_control/channels/telegram/bot"
require_relative "agents_control/anchors/scheduler"
require_relative "agents_control/screen_watcher"
require_relative "agents_control/rate_limit_watcher"
require_relative "agents_control/doctor"
require_relative "agents_control/service"
require_relative "agents_control/daemon"
require_relative "agents_control/keyboard"
require_relative "agents_control/prompt"
require_relative "agents_control/menu"
require_relative "agents_control/console"
require_relative "agents_control/cli"
