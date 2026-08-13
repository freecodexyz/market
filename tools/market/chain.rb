# frozen_string_literal: true

module Market
  # Everything that talks to a chain, through Foundry's cast and forge.
  class Chain
    WEI_PER_ETHER = 10**18

    # Used only to label output. An id that is not listed is reported as-is rather than rejected.
    NETWORKS = {
      1 => "Ethereum",
      8453 => "Base",
      84532 => "Base Sepolia",
      11_155_111 => "Sepolia",
      31_337 => "Anvil"
    }.freeze

    # Renders "Base Sepolia (84532)" rather than "84532".
    def self.describe(id)
      return "unknown" if id.nil?

      name = NETWORKS[id.to_i]
      name ? "#{name} (#{id})" : id.to_s
    end

    # A contract created by a broadcast run.
    Deployed = Data.define(:name, :address, :block)

    attr_reader :rpc_url

    def initialize(rpc_url:, root: Dir.pwd)
      @rpc_url = rpc_url
      @root = root
    end

    def chain_id
      Integer(cast("chain-id"))
    end

    def reachable?
      chain_id
      true
    rescue CommandFailed
      false
    end

    def balance(address)
      Integer(cast("balance", address))
    end

    def balance_eth(address)
      (balance(address).to_f / WEI_PER_ETHER).round(6)
    end

    def contract?(address)
      cast("code", address) != "0x"
    end

    def address_of(private_key)
      Shell.capture("cast", "wallet", "address", "--private-key", private_key, chdir: root)
    end

    # Reads a value. `signature` carries the return type, e.g. `owner()(address)`.
    def call(address, signature, *args)
      cast("call", address, signature, *args)
    end

    # Reads a `string` return, which cast quotes.
    def call_string(address, signature, *args)
      call(address, signature, *args).delete_prefix('"').delete_suffix('"')
    end

    # Reads a numeric return. cast annotates large values as `1260258423 [1.26e9]`, so only the
    # leading token is the value.
    def call_integer(address, signature, *args)
      Integer(call(address, signature, *args).split.first)
    end

    def call_boolean(address, signature, *args)
      call(address, signature, *args) == "true"
    end

    # Reads a struct return. cast renders it as `(a, b, c)`, with the same annotations on each
    # numeric member as a bare integer return.
    def call_tuple(address, signature, *args)
      raw = call(address, signature, *args).strip
      raise InvalidState, "expected a tuple, got #{raw.inspect}" unless raw.start_with?("(") && raw.end_with?(")")

      raw[1..-2].split(",").map { |member| member.strip.split.first }
    end

    # Reads a value, returning nil when the call reverts. The registry reverts for an unregistered
    # repository.
    def try_call(address, signature, *args)
      call(address, signature, *args)
    rescue CommandFailed
      nil
    end

    def send_transaction(address, signature, *args, private_key:)
      cast("send", address, signature, *args, "--private-key", private_key)
    end

    # Runs a Foundry deploy script and returns the contracts it created.
    #
    # The script remains the single definition of how a deployment is wired. This supplies the
    # environment it expects and reads the addresses back from the broadcast artifact, which also
    # records the block each contract was included in.
    def run_script(script, env:, private_key:)
      Shell.stream(
        "forge", "script", File.join("script", script),
        "--rpc-url", rpc_url, "--broadcast", "--silent",
        env: env.merge("PRIVATE_KEY" => private_key), chdir: root
      )
      broadcast_results(script)
    end

    private

    attr_reader :root

    def cast(*argv)
      Shell.capture("cast", *argv, "--rpc-url", rpc_url, chdir: root)
    end

    def broadcast_results(script)
      path = File.join(root, "broadcast", script, chain_id.to_s, "run-latest.json")
      raise InvalidState, "no broadcast artifact at #{path}" unless File.exist?(path)

      artifact = JSON.parse(File.read(path))
      blocks = artifact.fetch("receipts", []).map { |receipt| to_integer(receipt["blockNumber"]) }

      artifact.fetch("transactions", [])
              .each_with_index
              .select { |transaction, _| transaction["transactionType"] == "CREATE" }
              .map do |transaction, index|
                Deployed.new(
                  name: transaction["contractName"],
                  address: transaction["contractAddress"],
                  block: blocks[index]
                )
              end
    end

    def to_integer(value)
      return value if value.is_a?(Integer)

      value.to_s.start_with?("0x") ? Integer(value, 16) : Integer(value)
    end
  end
end
