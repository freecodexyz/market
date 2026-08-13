# frozen_string_literal: true

require "json"
require "open3"

module Market
  # Runs external tools.
  #
  # Arguments are always passed as an argv array rather than a command string, so an address, a
  # repository slug or anything else that reaches this module can never be interpreted as shell
  # syntax.
  module Shell
    module_function

    # Runs `argv` and returns its stdout, raising {CommandFailed} on a non-zero exit.
    #
    # `chdir` matters more than it looks: gh and forge both resolve context from the working
    # directory, so a command has to run in the repository rather than wherever the shell happens
    # to be.
    def capture(*argv, env: {}, chdir: nil)
      argv = argv.flatten.map(&:to_s)
      stdout, stderr, status = Open3.capture3(stringify(env), *argv, **options(chdir))
      raise CommandFailed, failure(argv, status, stderr, stdout) unless status.success?

      stdout.strip
    end

    def capture_json(*argv, env: {}, chdir: nil)
      JSON.parse(capture(*argv, env: env, chdir: chdir))
    end

    # Streams output straight to the terminal, for long-running tools worth watching.
    def stream(*argv, env: {}, chdir: nil)
      argv = argv.flatten.map(&:to_s)
      return if system(stringify(env), *argv, **options(chdir))

      raise CommandFailed, "#{argv.first} failed"
    end

    # Looks the tool up on PATH directly; spawning a process just to ask is wasteful and needs a
    # shell of its own.
    def available?(tool)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, tool)
        File.file?(path) && File.executable?(path)
      end
    end

    def require_tools!(*tools)
      missing = tools.flatten.reject { |tool| available?(tool) }
      return if missing.empty?

      raise MissingRequirement, "not on PATH: #{missing.join(", ")}"
    end

    def options(chdir)
      chdir ? { chdir: chdir } : {}
    end

    def stringify(env)
      env.to_h { |key, value| [key.to_s, value&.to_s] }
    end

    def failure(argv, status, stderr, stdout)
      detail = stderr.strip.empty? ? stdout.strip : stderr.strip
      message = "#{argv.first} exited #{status.exitstatus}"
      detail.empty? ? message : "#{message}: #{detail.lines.first(6).join.strip}"
    end

    private_class_method :options, :stringify, :failure
  end
end
