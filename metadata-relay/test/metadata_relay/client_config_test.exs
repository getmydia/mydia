defmodule MetadataRelay.ClientConfigTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.ClientConfig

  @cae1_1 "https://cae1-1.relay.mydia.dev"
  @cae1_2 "https://cae1-2.relay.mydia.dev"

  describe "parse/1" do
    test "nil and blank are unset" do
      assert ClientConfig.parse(nil) == :unset
      assert ClientConfig.parse("") == :unset
      assert ClientConfig.parse("   ") == :unset
    end

    test "accepts one relay" do
      assert ClientConfig.parse(@cae1_1) == {:ok, [@cae1_1]}
    end

    test "accepts several, in order, ignoring spaces and a trailing comma" do
      assert ClientConfig.parse(" #{@cae1_2} , #{@cae1_1},") == {:ok, [@cae1_2, @cae1_1]}
    end

    test "rejects a value that lists no relays" do
      assert ClientConfig.parse(",,") == {:error, "no relays listed"}
    end

    for {label, bad} <- [
          {"an http URL", "http://relay.example.test"},
          {"a bare hostname", "relay.example.test"},
          {"an empty host", "https:///path"},
          {"a bare scheme", "https://"}
        ] do
      @bad bad
      test "rejects #{label}, even beside a good relay" do
        assert {:error, reason} = ClientConfig.parse(@cae1_1 <> "," <> @bad)
        assert reason =~ "not an https URL with a host"
      end
    end

    test "rejects a duplicate" do
      assert {:error, reason} = ClientConfig.parse("#{@cae1_1},#{@cae1_1}")
      assert reason =~ "listed twice"
    end
  end

  describe "default_relay_urls/0" do
    test "passes its own rules" do
      defaults = ClientConfig.default_relay_urls()
      assert ClientConfig.parse(Enum.join(defaults, ",")) == {:ok, defaults}
    end

    test "the built-in list carries both mydia relays" do
      assert ClientConfig.default_relay_urls() == [@cae1_1, @cae1_2]
    end
  end
end
