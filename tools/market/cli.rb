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
        royalty collect <pool>            push a pool's fees into its repository's bucket
        royalty claim <repoId> <token>    withdraw a bucket as the current holder

      Options:
        --rpc-url URL              RPC endpoint (deploy; remembered afterwards)
        --verifier ADDRESS         deployed GithubOidcVerifier to trust (deploy)
        --airlock ADDRESS          Doppler Airlock to launch markets through (deploy)
        --splitter-owner ADDRESS   account allowed to sweep integrator fees (deploy)
        --registrar-key KEY        gas-paying key, stored as the registrar secret (configure)
        --to ADDRESS               payout recipient (royalty claim)
        --dry-run                  report the plan without writing anything (configure)
        -h, --help                 this message
        -v, --version              version

      The signing key is read from MARKET_PRIVATE_KEY or PRIVATE_KEY, or prompted for.
      It is never written to #{Config::FILENAME}.

      This project does not deploy a verifier. Point --verifier at the one the identity
      repository already runs; its signing keys are mirrored there.
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
        o.on("--verifier ADDRESS") { |value| options[:verifier] = value }
        o.on("--airlock ADDRESS") { |value| options[:airlock] = value }
        o.on("--splitter-owner ADDRESS") { |value| options[:splitter_owner] = value }
        o.on("--registrar-key KEY") { |value| options[:registrar_key] = value }
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
          rpc_url: options[:rpc_url], verifier: options[:verifier],
          airlock: options[:airlock], splitter_owner: options[:splitter_owner]
        )
      when "status" then deployment.status
      when "configure"
        deployment.configure(registrar_key: options[:registrar_key], dry_run: options[:dry_run])
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
      when "collect" then registry.collect(address!("pool"))
      when "claim" then registry.claim(repo_id!, address!("token"), options[:to])
      else
        raise Error, "unknown royalty subcommand: #{subcommand.inspect}"
      end
    end

    def deployment
      @deployment ||= Deployment.new(root: root)
    end

    def registry
      @registry ||= Registry.new(deployment)
    end

    # Accepts a decimal repository id. GitHub ids are numeric and are what the contracts pin, so
    # anything else is a mistake worth catching before it reaches an RPC call.
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
