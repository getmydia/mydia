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

  describe "remap/3" do
    setup do
      show = media_item_fixture(%{type: "tv_show", title: "Remap Me"})

      # Official ordering: one season of 4.
      for n <- 1..4 do
        episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: n,
          absolute_number: n,
          provider_episode_id: "ep#{n}"
        })
      end

      # DVD ordering: two seasons of 2.
      mapping = %{"ep1" => {1, 1}, "ep2" => {1, 2}, "ep3" => {2, 1}, "ep4" => {2, 2}}

      %{show: show, mapping: mapping, ids: ids_by_provider_id(show)}
    end

    test "moves episodes without creating or deleting any", %{show: show, mapping: mapping} do
      assert {:ok, 4} = SeasonOrder.remap(show, :dvd, mapping)

      episodes = Mydia.Media.list_episodes(show.id)
      assert length(episodes) == 4

      assert Enum.sort(Enum.map(episodes, &{&1.season_number, &1.episode_number})) ==
               [{1, 1}, {1, 2}, {2, 1}, {2, 2}]
    end

    # Coordinates alone would also be satisfied by a delete-and-recreate, which
    # is exactly the failure mode this whole design exists to avoid. Compare row
    # ids: they are what media_files.episode_id, downloads and watch history
    # point at.
    test "keeps the same rows, identified by id", %{show: show, mapping: mapping, ids: ids} do
      assert {:ok, 4} = SeasonOrder.remap(show, :dvd, mapping)

      assert ids_by_provider_id(show) == ids
    end

    test "preserves media file links across the switch", %{show: show, mapping: mapping} do
      episode = Mydia.Media.find_episode(show.id, 1, 3)
      file = media_file_fixture(%{episode_id: episode.id})

      {:ok, _} = SeasonOrder.remap(show, :dvd, mapping)

      moved = Mydia.Media.find_episode(show.id, 2, 1)
      assert moved.id == episode.id
      assert Repo.get!(Mydia.Library.MediaFile, file.id).episode_id == episode.id
    end

    test "records the target ordering on the show", %{show: show, mapping: mapping} do
      assert Repo.get!(MediaItem, show.id).season_order == nil

      {:ok, _} = SeasonOrder.remap(show, :dvd, mapping)

      assert Repo.get!(MediaItem, show.id).season_order == :dvd
    end

    test "is reversible, down to the row ids", %{show: show, mapping: mapping, ids: ids} do
      {:ok, _} = SeasonOrder.remap(show, :dvd, mapping)

      back = %{"ep1" => {1, 1}, "ep2" => {1, 2}, "ep3" => {1, 3}, "ep4" => {1, 4}}
      {:ok, _} = SeasonOrder.remap(show, :official, back)

      assert Enum.map(1..4, fn n ->
               Mydia.Media.find_episode(show.id, 1, n).provider_episode_id
             end) == ["ep1", "ep2", "ep3", "ep4"]

      # Same rows throughout: a round trip that recreated them would land on the
      # same coordinates with new ids.
      assert ids_by_provider_id(show) == ids
      assert Repo.get!(MediaItem, show.id).season_order == :official
    end

    test "survives a mapping that collides with current numbering", %{show: show} do
      # Swap two episodes. A naive single-pass UPDATE trips the unique index
      # halfway through.
      swap = %{"ep1" => {1, 2}, "ep2" => {1, 1}, "ep3" => {1, 3}, "ep4" => {1, 4}}

      assert {:ok, 4} = SeasonOrder.remap(show, :official, swap)
      assert Mydia.Media.find_episode(show.id, 1, 1).provider_episode_id == "ep2"
      assert Mydia.Media.find_episode(show.id, 1, 2).provider_episode_id == "ep1"
    end

    # A row the target ordering never mentions must end up back where it
    # started, not parked at the internal +1000 offset. Nothing else in the
    # suite would notice a show whose specials silently moved to season 1000.
    test "restores rows the mapping does not mention", %{show: show} do
      partial = %{"ep1" => {2, 1}, "ep2" => {2, 2}}

      assert {:ok, 2} = SeasonOrder.remap(show, :dvd, partial)

      assert Mydia.Media.find_episode(show.id, 1, 3).provider_episode_id == "ep3"
      assert Mydia.Media.find_episode(show.id, 1, 4).provider_episode_id == "ep4"

      assert Enum.sort(
               Enum.map(
                 Mydia.Media.list_episodes(show.id),
                 &{&1.season_number, &1.episode_number}
               )
             ) == [{1, 3}, {1, 4}, {2, 1}, {2, 2}]
    end

    test "refuses when an episode has no provider id", %{show: show, mapping: mapping} do
      episode = Mydia.Media.find_episode(show.id, 1, 2)
      {:ok, _} = Mydia.Media.update_episode(episode, %{provider_episode_id: nil})

      before = coordinates(show)

      assert {:error, :missing_provider_ids} = SeasonOrder.remap(show, :dvd, mapping)

      # And nothing moved.
      assert Mydia.Media.find_episode(show.id, 1, 3).provider_episode_id == "ep3"
      assert coordinates(show) == before
      assert Repo.get!(MediaItem, show.id).season_order == nil
    end

    # Two rows cannot share a slot. Refusing before the first write is what
    # keeps a half-remapped show off the table: the damage would be silent and
    # the user could not tell which episodes moved.
    test "refuses a mapping that would put two episodes in one slot", %{show: show} do
      # ep1 is moved onto ep3's slot, and ep3 is not mentioned so it stays put.
      conflicting = %{"ep1" => {1, 3}}

      before = coordinates(show)

      assert {:error, :conflicting_mapping} = SeasonOrder.remap(show, :dvd, conflicting)

      assert coordinates(show) == before
      assert Repo.get!(MediaItem, show.id).season_order == nil
    end
  end

  defp ids_by_provider_id(show) do
    show.id
    |> Mydia.Media.list_episodes()
    |> Map.new(&{&1.provider_episode_id, &1.id})
  end

  defp coordinates(show) do
    show.id
    |> Mydia.Media.list_episodes()
    |> Enum.map(&{&1.provider_episode_id, &1.season_number, &1.episode_number})
    |> Enum.sort()
  end

  describe "available/2" do
    setup do
      %{config: Mydia.Metadata.default_relay_config()}
    end

    test "offers the orderings TVDB publishes", %{config: config} do
      tvdb_id = System.unique_integer([:positive])
      show = tvdb_show(tvdb_id)
      seed_raw_seasons(tvdb_id, [{"official", 1}, {"dvd", 4}])

      assert {:ok, [:official, :dvd]} = SeasonOrder.available(show, config)
    end

    test "drops ordering types season_order cannot store", %{config: config} do
      tvdb_id = System.unique_integer([:positive])
      show = tvdb_show(tvdb_id)
      seed_raw_seasons(tvdb_id, [{"official", 1}, {"alternate", 3}, {"regional", 2}])

      assert {:ok, [:official]} = SeasonOrder.available(show, config)
    end

    # The option order must not depend on the payload's key order, or the
    # selector would reshuffle itself between shows.
    test "returns the orderings in values/0 order", %{config: config} do
      tvdb_id = System.unique_integer([:positive])
      show = tvdb_show(tvdb_id)
      seed_raw_seasons(tvdb_id, [{"absolute", 1}, {"dvd", 4}, {"official", 1}])

      assert {:ok, [:official, :dvd, :absolute]} = SeasonOrder.available(show, config)
    end

    # A show sitting on an ordering TVDB no longer publishes would otherwise
    # render a selector with no matching option, misreporting where it is and
    # offering no way back.
    test "always includes the ordering the show is already in", %{config: config} do
      tvdb_id = System.unique_integer([:positive])
      show = tvdb_show(tvdb_id, %{season_order: :dvd})
      seed_raw_seasons(tvdb_id, [{"official", 1}])

      assert {:ok, [:official, :dvd]} = SeasonOrder.available(show, config)
    end

    test "refuses a show with no TVDB id", %{config: config} do
      show = media_item_fixture(%{type: "tv_show", title: "No Id", metadata_source: :tvdb})

      assert {:error, :missing_tvdb_id} = SeasonOrder.available(show, config)
    end
  end

  defp tvdb_show(tvdb_id, attrs \\ %{}) do
    media_item_fixture(
      Map.merge(
        %{
          type: "tv_show",
          title: "Ordering #{tvdb_id}",
          tvdb_id: tvdb_id,
          metadata_source: :tvdb
        },
        attrs
      )
    )
  end

  # Seeds the cache key `Relay.fetch_raw_seasons/2` reads, so the lookup never
  # makes an HTTP request. `Mydia.Metadata.Cache` is a shared ETS table, but the
  # key carries a unique tvdb_id per test, so this stays safe under async: true.
  defp seed_raw_seasons(tvdb_id, types) do
    seasons =
      Enum.flat_map(types, fn {type, season_count} ->
        Enum.map(1..season_count, fn number ->
          %{
            "id" => System.unique_integer([:positive]),
            "number" => number,
            "type" => %{"type" => type}
          }
        end)
      end)

    Mydia.Metadata.Cache.put("tvdb_raw_seasons:#{tvdb_id}", seasons, ttl: :timer.hours(1))

    :ok
  end
end
