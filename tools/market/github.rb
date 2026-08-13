# frozen_string_literal: true

module Market
  # The GitHub side of an operation, through the gh CLI.
  #
  # Using gh rather than the REST API directly means the operator's existing login is the only
  # credential involved, and there is no token for this tool to store or leak.
  class GitHub
    # The attestation workflow pinned on-chain. Renaming or moving it is a protocol change: proofs
    # carry its ref, and the registry compares that ref exactly.
    WORKFLOW_PATH = ".github/workflows/register-rik.yml"

    Repo = Data.define(:slug, :database_id, :owner, :owner_id, :default_branch) do
      # The exact `job_workflow_ref` claim the attestation workflow will produce.
      #
      # Assembling this by hand is the easiest way to deploy a registry that rejects every proof,
      # which is why it is derived from the repository rather than typed in.
      def job_workflow_ref
        "#{slug}/#{WORKFLOW_PATH}@refs/heads/#{default_branch}"
      end
    end

    def self.available?
      Shell.available?("gh")
    end

    def initialize(root: Dir.pwd)
      @root = root
      @cache = {}
    end

    def authenticated?
      Shell.capture("gh", "auth", "status", chdir: root)
      true
    rescue CommandFailed
      false
    end

    # Resolves `owner/repo` to the numeric ids the contracts pin.
    #
    # `gh repo view` only exposes the GraphQL node id, so this goes through the REST endpoint. Both
    # ids matter: `RIK` mints the repository id and records the owner id, and typing either by hand
    # is the easiest way to produce a proof that will never verify.
    def repo(slug)
      @cache[slug] ||= build(Shell.capture_json("gh", "api", "repos/#{slug}", chdir: root))
    end

    # The repository the current checkout points at.
    def current_repo
      @cache[:current] ||= build(Shell.capture_json("gh", "api", "repos/{owner}/{repo}", chdir: root))
    end

    def set_variable(name, value)
      Shell.capture("gh", "variable", "set", name, "--body", value.to_s, chdir: root)
    end

    def set_secret(name, value)
      Shell.capture("gh", "secret", "set", name, "--body", value.to_s, chdir: root)
    end

    private

    attr_reader :root

    def build(data)
      owner = data.fetch("owner")
      Repo.new(
        slug: data.fetch("full_name"),
        database_id: data.fetch("id"),
        owner: owner.fetch("login"),
        owner_id: owner.fetch("id"),
        default_branch: data.fetch("default_branch")
      )
    end
  end
end
