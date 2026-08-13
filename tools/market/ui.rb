# frozen_string_literal: true

require "io/console"

module Market
  # Terminal output. Colour is opt-out through NO_COLOR and is dropped when stdout is redirected,
  # so piping a command somewhere yields plain text.
  module UI
    CODES = { red: 31, green: 32, yellow: 33, blue: 34, grey: 90 }.freeze
    LABEL_WIDTH = 22

    module_function

    def colour?
      $stdout.tty? && !ENV.key?("NO_COLOR")
    end

    def paint(text, colour)
      return text unless colour?

      "\e[#{CODES.fetch(colour)}m#{text}\e[0m"
    end

    def heading(text)
      puts
      puts paint(text, :blue)
    end

    def step(text)
      puts "#{paint("→", :blue)} #{text}"
    end

    def ok(text)
      puts "#{paint("✓", :green)} #{text}"
    end

    def warn(text)
      puts "#{paint("!", :yellow)} #{text}"
    end

    def error(text)
      $stderr.puts "#{paint("✗", :red)} #{text}"
    end

    def note(text)
      puts paint("  #{text}", :grey)
    end

    def field(label, value, colour: nil)
      rendered = value.nil? || value.to_s.empty? ? paint("unset", :grey) : value.to_s
      rendered = paint(rendered, colour) if colour
      puts "  #{label.to_s.ljust(LABEL_WIDTH)} #{rendered}"
    end

    # Reads a secret without echoing it. Falls back to a normal read when there is no terminal, so
    # the tool stays usable from a pipe.
    def read_secret(prompt)
      $stderr.print "#{prompt}: "
      value = $stdin.tty? ? $stdin.noecho(&:gets) : $stdin.gets
      $stderr.puts
      value.to_s.strip
    end

    def confirm?(question)
      return true unless $stdin.tty?

      $stderr.print "#{question} [y/N] "
      $stdin.gets.to_s.strip.casecmp?("y")
    end
  end
end
