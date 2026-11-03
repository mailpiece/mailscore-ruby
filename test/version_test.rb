require "test_helper"

class MailScore::Client::VersionTest < Minitest::Test
  def test_the_version_is_a_release_number
    assert_match(/\A\d+\.\d+\.\d+\z/, MailScore::Client::VERSION)
  end
end
