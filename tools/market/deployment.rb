# frozen_string_literal: true

module Market
  # Deploying and inspecting a deployment. Holds the wiring between the config file, the chain and
  # the repository so the CLI layer stays a thin dispatcher.
  class Deployment
    ISSUER = "https://token.actions.githubusercontent.com"

    RIK_SCRIPT = "DeployRIK.s.sol"
    MARKET_SCRIPT = "DeployMarket.s.sol"

    VARIABLES = {
      "FCF_RIK_ADDRESS" => :rik,
      "FCF_LAUNCHER_ADDRESS" => :launcher,
      "FCF_SPLITTER_ADDRESS" => :splitter,
      "FCF_RPC_URL" => :rpc_url,
      "FCF_RIK_FROM_BLOCK" => :deployed_at
    }.freeze

    # Pays gas for registrations and nothing else. `register` names its own beneficiary through the
    # `aud` claim, so this key holds no authority over the registry.
    REGISTRAR_SECRET = "FCF_REGISTRAR_PRIVATE_KEY"

    # Optional. Lets the attestation workflow ask GitHub whether an issue opener holds `admin` on
    # the repository being claimed, which is how organisation repositories are proven without the
    # organisation touching them. The app needs `Metadata: read` and nothing else.
    APP_ID_VARIABLE = "FCF_APP_ID"
    APP_KEY_SECRET = "FCF_APP_PRIVATE_KEY"

    def initialize(root: Dir.pwd)
      @root = root
      @config = Config.load(root)
      @github = GitHub.new(root: root)
    end

    attr_reader :config

    # --- commands -----------------------------------------------------------

    def doctor
      UI.heading "Tooling"
      %w[forge cast gh].each do |tool|
        Shell.available?(tool) ? UI.ok(tool) : UI.error("#{tool} is not on PATH")
      end

      UI.heading "GitHub"
      if !GitHub.available?
        UI.error "gh is not on PATH"
      elsif github.authenticated?
        UI.ok "authenticated"
      else
        UI.error "gh is not authenticated; run gh auth login"
      end

      UI.heading "Chain"
      if config.rpc_url.to_s.empty?
        UI.warn "no RPC configured; pass --rpc-url to deploy"
      elsif chain.reachable?
        UI.ok "#{config.rpc_url} (chain #{chain.chain_id})"
      else
        UI.error "#{config.rpc_url} is unreachable"
      end

      UI.heading "Verifier"
      report_verifier

      UI.heading "Deployment"
      if config.deployed?
        UI.ok "recorded in #{Config::FILENAME}"
      elsif config.registry_deployed?
        UI.warn "registry deployed, market contracts missing; run market deploy"
      else
        UI.warn "nothing deployed yet"
      end
      nil
    end

    def deploy(rpc_url: nil, verifier: nil, airlock: nil, splitter_owner: nil, rik_owner: nil,
               attestation_repo_id: nil, job_workflow_ref: nil)
      Shell.require_tools!("forge", "cast")

      config.rpc_url = rpc_url if rpc_url
      config.verifier = verifier if verifier
      config.airlock = airlock if airlock

      raise MissingRequirement, "no RPC URL; pass --rpc-url" if config.rpc_url.to_s.empty?
      raise MissingRequirement, "no verifier; pass --verifier" if config.verifier.to_s.empty?
      raise MissingRequirement, "no Airlock; pass --airlock" if config.airlock.to_s.empty?
      raise InvalidState, "#{config.rpc_url} is unreachable" unless chain.reachable?

      deployer = chain.address_of(private_key)
      # Defaulted here rather than in the script, so whoever ends up holding each authority is
      # printed in the plan and recorded in the config instead of being implied by a key.
      config.splitter_owner = splitter_owner || config.splitter_owner || deployer
      config.rik_owner = rik_owner || config.rik_owner || deployer

      # Derived from the checkout rather than typed, because a hand-assembled workflow ref is the
      # easiest way to deploy a registry that rejects every proof. The override exists for a local
      # chain and for a checkout with no GitHub remote, and says so out loud.
      if attestation_repo_id && job_workflow_ref
        config.attestation_repo_id = Integer(attestation_repo_id)
        config.job_workflow_ref = job_workflow_ref
        attestation_source = "supplied by hand"
      else
        Shell.require_tools!("gh")
        repo = github.current_repo
        config.attestation_repo_id = repo.database_id
        config.job_workflow_ref = repo.job_workflow_ref
        attestation_source = repo.slug
      end

      UI.heading "Plan"
      UI.field "chain", chain.chain_id
      UI.field "deployer", deployer
      UI.field "balance", "#{chain.balance_eth(deployer)} ETH"
      UI.field "verifier", config.verifier
      UI.field "airlock", config.airlock
      UI.field "attestation repo", "#{attestation_source} (#{config.attestation_repo_id})"
      UI.field "workflow ref", config.job_workflow_ref
      UI.warn "attestation source was typed, not derived from the checkout" if attestation_repo_id
      UI.field "rik owner", config.rik_owner
      UI.note "the rik owner can repoint the attestation source, and so can mint any repository's key"
      UI.field "splitter owner", config.splitter_owner
      UI.note "the splitter owner can sweep integrator fees; it cannot touch a repository's bucket"

      raise InvalidState, "deployer has no balance" if chain.balance(deployer).zero?
      raise InvalidState, "verifier #{config.verifier} has no code" unless chain.contract?(config.verifier)
      raise InvalidState, "cancelled" unless UI.confirm?("\nDeploy?")

      UI.heading "Deploying"
      UI.step "RIK"
      rik = expect_contract(
        chain.run_script(
          RIK_SCRIPT,
          env: {
            "JWT_VERIFIER_ADDRESS" => config.verifier,
            "RIK_OWNER" => config.rik_owner,
            "ATTESTATION_REPO_ID" => config.attestation_repo_id,
            "JOB_WORKFLOW_REF" => config.job_workflow_ref
          },
          private_key: private_key
        ),
        "RIK"
      )
      UI.ok "#{rik.address} (block #{rik.block})"

      UI.step "RIKLauncher and RIKRoyaltySplitter"
      created = chain.run_script(
        MARKET_SCRIPT,
        env: {
          "AIRLOCK_ADDRESS" => config.airlock,
          "RIK_ADDRESS" => rik.address,
          "SPLITTER_OWNER" => config.splitter_owner
        },
        private_key: private_key
      )
      launcher = expect_contract(created, "RIKLauncher")
      splitter = expect_contract(created, "RIKRoyaltySplitter")
      UI.ok "#{launcher.address} (block #{launcher.block})"
      UI.ok "#{splitter.address} (block #{splitter.block})"

      config.chain_id = chain.chain_id
      config.rik = rik.address
      config.launcher = launcher.address
      config.splitter = splitter.address
      config.deployed_at = rik.block
      config.save

      UI.heading "Saved"
      UI.note "#{Config::FILENAME} updated. Next: market status, then market configure."
      unless config.rik_owner.to_s.casecmp?(deployer)
        UI.warn "ownership of RIK is pending: #{config.rik_owner} must call acceptOwnership"
        UI.note "until it does, the deployer key still controls the attestation source"
      end
      nil
    end

    def status
      require_registry!

      UI.heading "Recorded"
      UI.field "chain", config.chain_id
      UI.field "rpc", config.rpc_url
      UI.field "verifier", config.verifier
      UI.field "airlock", config.airlock
      UI.field "rik", config.rik
      UI.field "launcher", config.launcher
      UI.field "splitter", config.splitter
      UI.field "from block", config.deployed_at

      unless chain.reachable?
        UI.error "#{config.rpc_url} is unreachable"
        return
      end

      UI.heading "Registry"
      UI.field "name", chain.call_string(config.rik, "name()(string)")
      UI.field "symbol", chain.call_string(config.rik, "symbol()(string)")
      UI.field "expected event", chain.call_string(config.rik, "expectedEventName()(string)")
      compare "verifier", chain.call(config.rik, "jwt()(address)"), config.verifier
      UI.field "owner", chain.call(config.rik, "owner()(address)")
      pending_rik = chain.call(config.rik, "pendingOwner()(address)")
      UI.field "pending owner", zero?(pending_rik) ? "none" : pending_rik

      UI.heading "Attestation source"
      report_attestation_source

      return UI.warn "market contracts not deployed yet" unless config.deployed?

      UI.heading "Market"
      compare "launcher registry", chain.call(config.launcher, "registry()(address)"), config.rik
      compare "launcher splitter", chain.call(config.launcher, "splitter()(address)"), config.splitter
      compare "launcher airlock", chain.call(config.launcher, "airlock()(address)"), config.airlock
      compare "splitter launcher", chain.call(config.splitter, "launcher()(address)"), config.launcher
      compare "splitter registry", chain.call(config.splitter, "registry()(address)"), config.rik
      compare "splitter airlock", chain.call(config.splitter, "airlock()(address)"), config.airlock
      UI.field "splitter owner", chain.call(config.splitter, "owner()(address)")
      pending = chain.call(config.splitter, "pendingOwner()(address)")
      UI.field "pending owner", zero?(pending) ? "none" : pending

      UI.heading "Verifier"
      report_verifier
      nil
    end

    def configure(registrar_key: nil, app_id: nil, app_private_key: nil, dry_run: false)
      require_deployment!
      Shell.require_tools!("gh")

      UI.note "dry run against #{github.current_repo.slug}, nothing will be written" if dry_run

      UI.heading "Repository variables"
      VARIABLES.each do |name, field|
        value = config.public_send(field)
        if value.to_s.empty?
          UI.warn "#{name} skipped, #{field} is unset"
          next
        end

        github.set_variable(name, value) unless dry_run
        UI.ok "#{name} = #{value}"
      end

      id = app_id || ENV.fetch(APP_ID_VARIABLE, nil)
      if id.to_s.empty?
        UI.warn "#{APP_ID_VARIABLE} skipped; pass --app-id to enable the organisation path"
      else
        github.set_variable(APP_ID_VARIABLE, id) unless dry_run
        UI.ok "#{APP_ID_VARIABLE} = #{id}"
      end

      UI.heading "Repository secrets"
      key = registrar_key || ENV.fetch(REGISTRAR_SECRET, nil)
      if key.to_s.empty?
        UI.warn "#{REGISTRAR_SECRET} skipped; pass --registrar-key or set it in the environment"
        UI.note "Only pays gas for registrations. Keep it funded, and hold nothing else with it."
      else
        github.set_secret(REGISTRAR_SECRET, key) unless dry_run
        UI.ok REGISTRAR_SECRET
      end

      app_key = app_private_key || ENV.fetch(APP_KEY_SECRET, nil)
      if app_key.to_s.empty?
        UI.warn "#{APP_KEY_SECRET} skipped; without it, organisations prove control with a topic"
      else
        github.set_secret(APP_KEY_SECRET, app_key) unless dry_run
        UI.ok APP_KEY_SECRET
      end

      UI.note "there is no key-sync secret here; the verifier and its owner key live in identity"
      nil
    end

    # --- shared helpers -----------------------------------------------------

    def chain
      @chain ||= Chain.new(rpc_url: config.rpc_url, root: root)
    end

    def require_registry!
      return if config.registry_deployed?

      raise InvalidState, "nothing deployed yet; run market deploy"
    end

    def require_deployment!
      return if config.deployed?

      raise InvalidState, "market contracts not deployed yet; run market deploy"
    end

    # Read once, never written to disk, never echoed.
    def private_key
      @private_key ||= begin
        raw = ENV["MARKET_PRIVATE_KEY"] || ENV["PRIVATE_KEY"] || UI.read_secret("Deployer private key")
        raise MissingRequirement, "no private key provided" if raw.to_s.empty?

        raw.start_with?("0x") ? raw : "0x#{raw}"
      end
    end

    private

    attr_reader :root, :github

    def expect_contract(deployed, name)
      deployed.find { |contract| contract.name == name } ||
        raise(InvalidState, "#{name} was not created by the deploy script")
    end

    def zero?(address)
      address.to_s.match?(/\A0x0+\z/)
    end

    def compare(label, actual, expected)
      if actual.to_s.casecmp?(expected.to_s)
        UI.field label, actual, colour: :green
      else
        UI.field label, "#{actual} (expected #{expected})", colour: :red
      end
    end

    # The registry only accepts proofs from one workflow file in one repository. Both are read back
    # from the chain and compared against this checkout, because a mismatch is silent: every
    # registration simply fails, with nothing on-chain to explain why.
    def report_attestation_source
      on_chain_repo = chain.call_integer(config.rik, "attestationRepoId()(uint64)")
      on_chain_ref = chain.call_string(config.rik, "jobWorkflowRef()(string)")

      if on_chain_repo.zero? || on_chain_ref.empty?
        UI.error "not configured; the registry rejects every proof until it is"
        return
      end

      begin
        repo = github.current_repo
      rescue Error => e
        UI.field "repository id", on_chain_repo
        UI.field "workflow ref", on_chain_ref
        UI.warn "could not resolve this checkout to compare: #{e.message.lines.first.strip}"
        return
      end

      compare "repository id", on_chain_repo, repo.database_id
      compare "workflow ref", on_chain_ref, repo.job_workflow_ref
      UI.note "proofs come from #{GitHub::WORKFLOW_PATH} in #{repo.slug}, opened as an issue"
    rescue CommandFailed => e
      UI.warn "could not read the attestation source: #{e.message.lines.first.strip}"
    end

    def report_verifier
      if config.verifier.to_s.empty?
        UI.warn "no verifier configured; pass --verifier"
        return
      end

      UI.field "address", config.verifier
      return UI.warn "chain unreachable, cannot check" if config.rpc_url.to_s.empty? || !chain.reachable?

      unless chain.contract?(config.verifier)
        UI.error "no code at #{config.verifier}"
        return
      end

      issuer = chain.call_string(config.verifier, "expectedIssuer()(string)")
      compare "issuer", issuer, ISSUER
      UI.field "owner", chain.call(config.verifier, "owner()(address)")
      UI.note "signing keys are mirrored by the identity repository, not by this one"
    rescue CommandFailed => e
      UI.warn "could not read the verifier: #{e.message.lines.first.strip}"
    end
  end
end
