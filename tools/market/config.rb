# frozen_string_literal: true

require "yaml"

module Market
  # What the tool remembers between runs, kept beside the repository in `.market.yml`.
  #
  # Deliberately holds no secrets. Keys are read from the environment or prompted for on each
  # command that needs one, so this file stays safe to leave lying around.
  class Config
    FILENAME = ".market.yml"

    FIELDS = %i[
      rpc_url
      chain_id
      verifier
      airlock
      rik
      launcher
      splitter
      rik_owner
      splitter_owner
      attestation_repo_id
      job_workflow_ref
      deployed_at
    ].freeze

    attr_accessor(*FIELDS)
    attr_reader :path

    def self.load(root)
      path = File.join(root, FILENAME)
      stored = File.exist?(path) ? YAML.safe_load_file(path) || {} : {}
      new(path: path, **stored.transform_keys(&:to_sym).slice(*FIELDS))
    end

    def initialize(path:, **values)
      @path = path
      FIELDS.each { |field| instance_variable_set(:"@#{field}", values[field]) }
    end

    def save
      File.write(path, +"# Written by bin/market. Safe to commit only if the endpoints are public.\n" << to_yaml)
      self
    end

    # The registry alone is enough to inspect repositories; the market half can come later.
    def registry_deployed?
      !rik.to_s.empty?
    end

    def deployed?
      registry_deployed? && !launcher.to_s.empty? && !splitter.to_s.empty?
    end

    def to_h
      FIELDS.to_h { |field| [field.to_s, public_send(field)] }.compact
    end

    def to_yaml
      to_h.to_yaml.sub(/\A---\n/, "")
    end
  end
end
