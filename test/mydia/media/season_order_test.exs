defmodule Mydia.Media.SeasonOrderTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Media.MediaItem
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

  # This is the property the whole design rests on: nil means "never asked"
  # and is what the (future) suggestion banner keys on, while an explicit
  # :official means "asked and declined" and retires it permanently. If the
  # schema field or the migration ever grew a default of :official, the two
  # states would collapse and the banner could never appear for any show —
  # a change that would look like a harmless cleanup and pass every other
  # test in the suite.
  test "season_order defaults to nil, not :official, on an uncast changeset" do
    changeset =
      MediaItem.changeset(%MediaItem{}, %{type: "movie", title: "The Matrix", year: 1999})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :season_order) == nil
  end

  test "season_order is nil after insert and reload when never set" do
    media_item = media_item_fixture()

    reloaded = Repo.get!(MediaItem, media_item.id)

    assert reloaded.season_order == nil
  end

  # The ordering list is written independently in the schema (as Ecto.Enum
  # values) and in SeasonOrder.values/0. Nothing else keeps them in sync, so
  # a future ordering (TVDB also exposes "alternate" and "regional") added to
  # one and not the other would silently desync rather than raise.
  test "the schema's season_order enum values agree with SeasonOrder.values/0" do
    assert Ecto.Enum.values(MediaItem, :season_order) == SeasonOrder.values()
  end
end
