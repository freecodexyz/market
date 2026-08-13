# frozen_string_literal: true

require "optparse"

module Market
  # Argument parsing and dispatch. Every command is one method on {Deployment} or {Registry}; this
  # layer only turns argv into that call and turns a raised {Error} into an exit status.
  class CLI
    USAGE = <<~TEXT
      market — deployment and operations helper for the market contracts

      Usage: market <command> [options]

      Commands:
        doctor                     check tooling, credentials and the recorded deployment
        deploy                     deploy RIK, the launcher and the splitter, then record them
        status                     compare the deployment against its own recorded wiring
        configure                  push the recorded values into repository variables and secrets

        rik show <repoId>          show a repository key, its record and its metadata
        rik of <owner/repo>        resolve a slug through gh, then show its key
        market show <repoId>       show the market launched for a repository

        royalty show <repoId> <token>     show what the current holder can withdraw
        royalty collect <asset>           push a market's fees into its repository's bucket
        royalty claim <repoId> <token>    withdraw a bucket as the current holder

      Options:
        --rpc-url URL              RPC endpoint (deploy; remembered afterwards)
        --chain-id ID              the chain you mean; refuses to act on any other
        --verifier ADDRESS         deployed GithubOidcVerifier to trust (deploy)
        --airlock ADDRESS          Doppler Airlock to launch markets through (deploy)
        --rik-owner ADDRESS        account that controls the attestation source (deploy)
        --attestation-repo-id ID   pin the attestation repository by hand (deploy)
        --job-workflow-ref REF     pin the attestation workflow by hand (deploy)
        --splitter-owner ADDRESS   account allowed to sweep integrator fees (deploy)
        --registrar-key KEY        gas-paying key, stored as the registrar secret (configure)
        --app-id ID                GitHub App id, for the organisation proof path (configure)
        --app-private-key PEM      GitHub App private key (configure)
        --to ADDRESS               payout recipient (royalty claim)
        --dry-run                  report the plan without writing anything (configure)
        -h, --help                 this message
        -v, --version              version

      The signing key is read from MARKET_PRIVATE_KEY or PRIVATE_KEY, or prompted for.
      It is never written to #{Config::FILENAME}.

      MARKET_RPC_URL and MARKET_CHAIN_ID override the recorded endpoint and pin the chain, so
      a Base Sepolia rehearsal is a variable rather than an edit:

        MARKET_RPC_URL=https://sepolia.base.org MARKET_CHAIN_ID=84532 ./bin/market status

      Anything that spends gas refuses to run against a chain other than the pinned one.

      This project does not deploy a verifier. Point --verifier at the one the identity
      repository already runs; its signing keys are mirrored there.

      Repositories are registered by opening an issue here, not from the command line.
      See ATTESTATION.md.
    TEXT

    def initialize(argv, root: Dir.pwd)
      @argv = argv.dup
      @root = root
      @options = { dry_run: false }
    end

    def run
      command = parse!
      if command.nil?
        puts USAGE
        return 0
      end

      dispatch(command)
      0
    rescue Error => e
      UI.error e.message
      1
    rescue Interrupt
      UI.error "interrupted"
      130
    end

    private

    attr_reader :argv, :root, :options

    def parse!
      parser.parse!(argv)
      argv.shift
    end

    def parser
      OptionParser.new do |o|
        o.on("--rpc-url URL") { |value| options[:rpc_url] = value }
        o.on("--chain-id ID") { |value| options[:chain_id] = value }
        o.on("--verifier ADDRESS") { |value| options[:verifier] = value }
        o.on("--airlock ADDRESS") { |value| options[:airlock] = value }
        o.on("--rik-owner ADDRESS") { |value| options[:rik_owner] = value }
        o.on("--attestation-repo-id ID") { |value| options[:attestation_repo_id] = value }
        o.on("--job-workflow-ref REF") { |value| options[:job_workflow_ref] = value }
        o.on("--splitter-owner ADDRESS") { |value| options[:splitter_owner] = value }
        o.on("--registrar-key KEY") { |value| options[:registrar_key] = value }
        o.on("--app-id ID") { |value| options[:app_id] = value }
        o.on("--app-private-key PEM") { |value| options[:app_private_key] = value }
        o.on("--to ADDRESS") { |value| options[:to] = value }
        o.on("--dry-run") { options[:dry_run] = true }
        o.on("-h", "--help") do
          puts USAGE
          exit 0
        end
        o.on("-v", "--version") do
          puts VERSION
          exit 0
        end
      end
    end

    def dispatch(command)
      case command
      when "doctor" then deployment.doctor
      when "deploy"
        deployment.deploy(
          rpc_url: options[:rpc_url], verifier: options[:verifier], airlock: options[:airlock],
          splitter_owner: options[:splitter_owner], rik_owner: options[:rik_owner],
          attestation_repo_id: options[:attestation_repo_id], job_workflow_ref: options[:job_workflow_ref]
        )
      when "status" then deployment.status
      when "configure"
        deployment.configure(
          registrar_key: options[:registrar_key], app_id: options[:app_id],
          app_private_key: options[:app_private_key], dry_run: options[:dry_run]
        )
      when "rik" then rik
      when "market" then market
      when "royalty" then royalty
      else
        raise Error, "unknown command: #{command}"
      end
    end

    def rik
      case (subcommand = argv.shift)
      when "show" then registry.show(repo_id!)
      when "of" then registry.show_slug(slug!)
      else
        raise Error, "unknown rik subcommand: #{subcommand.inspect}"
      end
    end

    def market
      subcommand = argv.shift
      raise Error, "unknown market subcommand: #{subcommand.inspect}" unless subcommand == "show"

      registry.show_market(repo_id!)
    end

    def royalty
      case (subcommand = argv.shift)
      when "show" then registry.claimable(repo_id!, address!("token"))
      when "collect" then registry.collect(address!("asset"))
      when "claim" then registry.claim(repo_id!, address!("token"), options[:to])
      else
        raise Error, "unknown royalty subcommand: #{subcommand.inspect}"
      end
    end

    def deployment
      @deployment ||= Deployment.new(root: root, chain_id: options[:chain_id])
    end

    def registry
      @registry ||= Registry.new(deployment)
    end

    # Accepts a decimal repository id. GitHub ids are numeric and are what the contracts pin, so
    # anything else is rejected before it reaches an RPC call.
    def repo_id!
      raw = argv.shift
      raise Error, "expected a repository id" if raw.to_s.empty?
      raise Error, "not a repository id: #{raw.inspect}" unless raw.match?(/\A\d+\z/)

      Integer(raw)
    end

    def address!(what)
      raw = argv.shift
      raise Error, "expected a #{what} address" if raw.to_s.empty?
      raise Error, "not an address: #{raw.inspect}" unless raw.match?(/\A0x[0-9a-fA-F]{40}\z/)

      raw
    end

    def slug!
      raw = argv.shift
      raise Error, "expected owner/repo" if raw.to_s.empty?
      raise Error, "not an owner/repo slug: #{raw.inspect}" unless raw.match?(%r{\A[\w.-]+/[\w.-]+\z})

      raw
    end
  end
end
