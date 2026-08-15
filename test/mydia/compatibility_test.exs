defmodule Mydia.CompatibilityTest do
  use ExUnit.Case, async: true

  alias Mydia.Compatibility

  describe "version floors" do
    test "min_player_version is a parseable semver string" do
      assert {:ok, _} = Version.parse(Compatibility.min_player_version())
    end

    test "recommended_player_version is a parseable semver string" do
      assert {:ok, _} = Version.parse(Compatibility.recommended_player_version())
    end

    test "the recommended floor is at or above the required floor" do
      assert Version.compare(
               Compatibility.recommended_player_version(),
               Compatibility.min_player_version()
             ) in [:gt, :eq]
    end
  end
end
