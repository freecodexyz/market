# frozen_string_literal: true

require "json"

module Market
  # Reading and operating a live deployment: repository keys, their markets, and their royalties.
  #
  # Everything here uses the deployment's recorded addresses, so a command takes no address beyond
  # the subject being queried.
  class Registry
    DATA_URI_PREFIX = "data:application/json;base64,"

    def initialize(deployment)
      @deployment = deployment
      @github = GitHub.new(root: Dir.pwd)
    end

    # --- repository keys ----------------------------------------------------

    # Resolves `owner/repo` through gh, then shows the key.
    def show_slug(slug)
      Shell.require_tools!("gh")
      repo = github.repo(slug)

      UI.heading "Repository"
      UI.field "slug", repo.slug
      UI.field "repository id", repo.database_id
      UI.field "owner", "#{repo.owner} (#{repo.owner_id})"
      UI.field "default branch", repo.default_branch

      show(repo.database_id)
    end

    def show(repo_id)
      deployment.require_registry!
      rik = deployment.config.rik

      UI.heading "Key"
      unless chain.call_boolean(rik, "isRegistered(uint256)(bool)", repo_id)
        UI.warn "repository #{repo_id} has no key yet"
        return
      end

      record = chain.call_tuple(rik, "repoOf(uint256)((uint64,uint64,uint64,uint64))", repo_id)
      UI.field "token id", repo_id
      UI.field "holder", chain.call(rik, "ownerOf(uint256)(address)", repo_id)
      UI.field "repository id", record[0]
      UI.field "owner id", record[1]
      # For an organisation repository the claimant and the owner are different accounts.
      UI.field "claimed by", record[2]
      UI.field "registered at", timestamp(record[3])

      metadata(rik, repo_id)
      show_market(repo_id) if deployment.config.deployed?
      nil
    end

    # --- markets ------------------------------------------------------------

    def show_market(repo_id)
      deployment.require_deployment!
      config = deployment.config

      asset = chain.call(config.launcher, "marketOf(uint256)(address)", repo_id)

      UI.heading "Market"
      if zero?(asset)
        UI.warn "no market launched for repository #{repo_id}"
        return
      end

      UI.field "asset", asset
      attributed = chain.call_integer(config.splitter, "repoIdOf(address)(uint256)", asset)
      if attributed.to_s == repo_id.to_s
        UI.field "attributed to", attributed, colour: :green
      else
        UI.field "attributed to", "#{attributed} (expected #{repo_id})", colour: :red
      end
      nil
    end

    # --- royalties ----------------------------------------------------------

    def claimable(repo_id, token)
      deployment.require_deployment!

      amount = chain.call_integer(deployment.config.splitter, "claimable(uint256,address)(uint256)", repo_id, token)

      UI.heading "Claimable"
      UI.field "repository", repo_id
      UI.field "token", token
      UI.field "amount", amount
      UI.field "holder", chain.call(deployment.config.rik, "ownerOf(uint256)(address)", repo_id)
      amount
    end

    # Pushes a market's accrued fees into the owning repository's bucket. Permissionless, so it is
    # safe to run for another repository; this is the entry point a keeper would use.
    #
    # The market is named by its asset, which is what the launcher recorded. Doppler holds fees in
    # its initializer and releases only a beneficiary's share, so the splitter has to make this call
    # itself; a keeper is paying the gas, not collecting the fees.
    def collect(asset)
      deployment.require_deployment!
      # Refuse to spend gas on a chain other than the one configured.
      deployment.require_expected_chain!

      repo_id = chain.call_integer(deployment.config.splitter, "repoIdOf(address)(uint256)", asset)
      raise InvalidState, "#{asset} is not a launched market" if repo_id.zero?

      UI.step "collecting fees for repository #{repo_id} from #{asset}"
      output = chain.send_transaction(
        deployment.config.splitter, "collectPoolFees(address)", asset, private_key: deployment.private_key
      )
      UI.ok "sent"
      UI.note output.lines.grep(/transactionHash/).first.to_s.strip
      nil
    end

    # Withdraws a bucket. The signing key must currently hold the repository's key.
    def claim(repo_id, token, to)
      deployment.require_deployment!
      deployment.require_expected_chain!
      config = deployment.config

      amount = chain.call_integer(config.splitter, "claimable(uint256,address)(uint256)", repo_id, token)
      raise InvalidState, "nothing to claim for repository #{repo_id} in #{token}" if amount.zero?

      holder = chain.call(config.rik, "ownerOf(uint256)(address)", repo_id)
      signer = chain.address_of(deployment.private_key)
      unless holder.casecmp?(signer)
        raise InvalidState, "signer #{signer} does not hold repository #{repo_id}; #{holder} does"
      end

      recipient = to || signer

      UI.heading "Claim"
      UI.field "repository", repo_id
      UI.field "token", token
      UI.field "amount", amount
      UI.field "recipient", recipient
      raise InvalidState, "cancelled" unless UI.confirm?("\nClaim?")

      output = chain.send_transaction(
        config.splitter, "claim(uint256,address,address)", repo_id, token, recipient,
        private_key: deployment.private_key
      )
      UI.ok "sent"
      UI.note output.lines.grep(/transactionHash/).first.to_s.strip
      nil
    end

    private

    attr_reader :deployment, :github

    def chain
      deployment.chain
    end

    def zero?(address)
      address.to_s.match?(/\A0x0+\z/)
    end

    def timestamp(value)
      seconds = Integer(value)
      "#{seconds} (#{Time.at(seconds).utc.strftime("%Y-%m-%d %H:%M:%S UTC")})"
    rescue ArgumentError, TypeError
      value
    end

    # Metadata is served on chain as a base64 data URI, so displaying it requires no request beyond
    # the RPC endpoint.
    def metadata(rik, repo_id)
      uri = chain.call_string(rik, "tokenURI(uint256)(string)", repo_id)
      return UI.warn "token URI is not an on-chain data URI" unless uri.start_with?(DATA_URI_PREFIX)

      parsed = JSON.parse(uri.delete_prefix(DATA_URI_PREFIX).unpack1("m"))

      UI.heading "Metadata"
      UI.field "name", parsed["name"]
      UI.field "image", parsed["image"]
      UI.field "external url", parsed["external_url"]
    rescue CommandFailed, JSON::ParserError => e
      UI.warn "could not read metadata: #{e.message.lines.first.strip}"
    end
  end
end
