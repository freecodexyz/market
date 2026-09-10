# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "tempfile"
require "open3"

class RegistrationRequestTest < Minitest::Test
  def test_chain_selection_and_untrusted_titles
    workflow = YAML.safe_load_file(File.expand_path("../workflows/register-rik.yml", __dir__))
    script = workflow.fetch("jobs").fetch("register").fetch("steps").find { |step| step["id"] == "parse" }.fetch("run")
    wallet = "0x#{'1' * 40}"
    cases = {
      "owner/repo #{wallet}" => ["ok", "8453"],
      "owner/repo #{wallet} 4663" => ["ok", "4663"],
      "  owner/repo   #{wallet}   8453  " => ["ok", "8453"],
      "owner/repo #{wallet} 46630" => ["invalid", nil],
      "owner/repo #{wallet} 4663 extra" => ["invalid", nil],
      "owner/repo 0x1234" => ["invalid", nil],
      "ordinary issue" => ["skip", nil],
      'owner/repo $(echo injected) 4663' => ["invalid", nil]
    }
    cases.each do |title, (expected_status, expected_chain)|
      Tempfile.create("registration-request") do |output|
        _stdout, stderr, result = Open3.capture3({ "ISSUE_TITLE" => title, "GITHUB_OUTPUT" => output.path }, "bash", "-c", script)
        assert result.success?, stderr
        fields = File.readlines(output.path, chomp: true).to_h { |line| line.split("=", 2) }
        assert_equal expected_status, fields["status"], title
        expected_chain.nil? ? assert_nil(fields["chain_id"], title) : assert_equal(expected_chain, fields["chain_id"], title)
      end
    end
  end
end
