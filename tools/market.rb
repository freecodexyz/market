# frozen_string_literal: true

# Deployment and operations helper for the market contracts.
#
# Wraps forge, cast and gh so that deploying, inspecting and operating a deployment is a single
# command each, with the addresses and endpoints remembered between runs instead of being retyped
# as environment variables.
module Market
  VERSION = "0.1.0"

  # Base for every failure this tool raises deliberately. Anything else escaping is a bug.
  Error = Class.new(StandardError)

  # A tool, credential or configuration value the command needs is absent.
  MissingRequirement = Class.new(Error)

  # An external command exited non-zero.
  CommandFailed = Class.new(Error)

  # The user asked for something the current state cannot satisfy.
  InvalidState = Class.new(Error)
end

require_relative "market/ui"
require_relative "market/shell"
require_relative "market/config"
require_relative "market/chain"
require_relative "market/github"
require_relative "market/deployment"
require_relative "market/registry"
require_relative "market/cli"
