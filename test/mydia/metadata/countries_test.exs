defmodule Mydia.Metadata.CountriesTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Countries

  test "all/0 includes Canada and is sorted by name" do
    assert {"CA", "Canada"} in Countries.all()

    names = Enum.map(Countries.all(), &elem(&1, 1))
    assert names == Enum.sort(names)
  end

  test "valid_code?/1 accepts listed uppercase codes only" do
    assert Countries.valid_code?("CA")
    refute Countries.valid_code?("ca")
    refute Countries.valid_code?("XX")
    refute Countries.valid_code?(nil)
    refute Countries.valid_code?(42)
  end

  test "name/1 returns the display name, falling back to the code" do
    assert Countries.name("CA") == "Canada"
    assert Countries.name("XX") == "XX"
  end

  test "flag/1 builds the regional-indicator emoji" do
    assert Countries.flag("CA") == "🇨🇦"
    assert Countries.flag("ca") == ""
  end
end
