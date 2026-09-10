# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../market"

class ConfigTest < Minitest::Test
  def test_independent_chain_records_and_github_names
    Dir.mktmpdir do |root|
      base = Market::Config.load(root)
      base.chain_id = 8453
      base.verifier = "0x#{'1' * 40}"
      base.save
      robinhood = Market::Config.load(root, filename: ".market-robinhood.yml")
      assert_nil robinhood.verifier
      robinhood.chain_id = 4663
      robinhood.verifier = "0x#{'2' * 40}"
      robinhood.save
      assert_equal base.verifier, Market::Config.load(root).verifier
      assert_equal robinhood.verifier, Market::Config.load(root, filename: ".market-robinhood.yml").verifier
      assert_equal "FCF_RPC_URL", base.github_name("FCF_RPC_URL")
      assert_equal "FCF_ROBINHOOD_RPC_URL", robinhood.github_name("FCF_RPC_URL")
      assert_equal "FCF_ROBINHOOD_REGISTRAR_PRIVATE_KEY", robinhood.github_name("FCF_REGISTRAR_PRIVATE_KEY")
      robinhood.chain_id = 46630
      assert_raises(Market::InvalidState) { robinhood.github_name("FCF_RPC_URL") }
    end
  end
end
