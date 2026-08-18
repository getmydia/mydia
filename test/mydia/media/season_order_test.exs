defmodule Mydia.Media.SeasonOrderTest do
  use Mydia.DataCase, async: true

  alias Mydia.Media.SeasonOrder

  test "values/0 lists the supported orderings" do
    assert SeasonOrder.values() == [:official, :dvd, :absolute]
  end

  test "tvdb_type/1 maps to TVDB's season type strings" do
    assert SeasonOrder.tvdb_type(:official) == "official"
    assert SeasonOrder.tvdb_type(:dvd) == "dvd"
    assert SeasonOrder.tvdb_type(:absolute) == "absolute"
  end

  test "tvdb_type/1 treats nil as official" do
    assert SeasonOrder.tvdb_type(nil) == "official"
  end
end
