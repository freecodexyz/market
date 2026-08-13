#!/usr/bin/env ruby
# frozen_string_literal: true

# Syntax-checks every `run:` block in every workflow, as bash receives it after YAML has stripped
# the block's indentation.
#
# A workflow is only exercised when its trigger fires, and the attestation workflow's trigger is a
# stranger opening an issue. That makes an unparseable `run:` block expensive to discover: it fails
# on somebody's registration rather than in CI.
#
# Usage: ruby .github/scripts/check-workflows.rb

require "yaml"

root = File.expand_path("../..", __dir__)
workflows = Dir[File.join(root, ".github/workflows/*.yml")].sort
failures = 0

workflows.each do |path|
  workflow = YAML.safe_load_file(path)
  name = File.basename(path)

  (workflow["jobs"] || {}).each do |job_id, job|
    (job["steps"] || []).each_with_index do |step, index|
      script = step["run"]
      next unless script

      label = "#{name}: #{job_id} / #{step["name"] || "step #{index}"}"
      output = IO.popen(["bash", "-n"], "w+", err: %i[child out]) do |io|
        io.write(script)
        io.close_write
        io.read
      end

      next if output.strip.empty?

      failures += 1
      warn "#{label}"
      output.strip.lines.first(5).each { |line| warn "  #{line.chomp}" }
    end
  end
end

if failures.zero?
  puts "workflows: every run block parses"
  exit 0
end

warn "workflows: #{failures} run block(s) failed to parse"
exit 1
