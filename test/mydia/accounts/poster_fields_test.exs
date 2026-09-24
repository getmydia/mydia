defmodule Mydia.Accounts.PosterFieldsTest do
  use ExUnit.Case, async: true

  alias Mydia.Accounts.PosterFields

  test "defaults reproduce the card as it rendered before the preference existed" do
    assert PosterFields.default_keys() == [
             :playback,
             :quality,
             :status,
             :category,
             :year,
             :episodes
           ]
  end

  test "catalog lists every key once, new badges last" do
    keys = Enum.map(PosterFields.catalog(), &elem(&1, 0))
    assert keys == Enum.uniq(keys)
    assert Enum.take(keys, -2) == [:content_rating, :show_status]
  end

  describe "resolve/1" do
    test "nil and non-lists give the defaults" do
      assert PosterFields.resolve(nil) == PosterFields.default_keys()
      assert PosterFields.resolve("quality") == PosterFields.default_keys()
    end

    test "an empty list stays empty" do
      assert PosterFields.resolve([]) == []
    end

    test "drops unknown keys and duplicates and returns catalog order" do
      assert PosterFields.resolve(["show_status", "bogus", "year", "year", :quality]) ==
               [:quality, :year, :show_status]
    end
  end

  test "show?/2" do
    assert PosterFields.show?([:year], :year)
    refute PosterFields.show?([:year], :quality)
  end
end
