defmodule Mydia.PlayerTest do
  # async: false - enabled?/0 reads application env, which is global.
  use ExUnit.Case, async: false

  alias Mydia.Player

  describe "parse_env!/1" do
    test "treats unset and empty as on" do
      assert Player.parse_env!(nil)
      assert Player.parse_env!("")
    end

    test "accepts the four boolean spellings" do
      assert Player.parse_env!("true")
      assert Player.parse_env!("1")
      refute Player.parse_env!("false")
      refute Player.parse_env!("0")
    end

    test "raises on anything else, naming the variable" do
      assert_raise ArgumentError, ~r/ENABLE_PLAYER/, fn -> Player.parse_env!("flase") end
      assert_raise ArgumentError, ~r/ENABLE_PLAYER/, fn -> Player.parse_env!("TRUE") end
    end
  end

  describe "enabled?/0" do
    setup do
      previous = Application.fetch_env(:mydia, :player_enabled)
      on_exit(fn -> restore(previous) end)
    end

    test "defaults to on" do
      Application.delete_env(:mydia, :player_enabled)
      assert Player.enabled?()
    end

    test "reads the boot value" do
      Application.put_env(:mydia, :player_enabled, false)
      refute Player.enabled?()
    end
  end

  defp restore({:ok, value}), do: Application.put_env(:mydia, :player_enabled, value)
  defp restore(:error), do: Application.delete_env(:mydia, :player_enabled)
end
