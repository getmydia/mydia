defmodule MydiaWeb.MediaLive.Show.AddConfigEventsTest do
  @moduledoc """
  Covers `franchise_entry?/2`'s provider guard.

  `Ref.parse/1` accepts `tvdb:<id>`, but a franchise is always a TMDB
  collection (`FranchiseEntry` only ever carries `tmdb_id`). Before this
  guard, `franchise_entry?/2` matched on the ref's bare id alone, so a
  `{:tvdb, id}` ref could be routed into the franchise/movie-only add and
  request paths whenever `id` happened to collide with a real franchise
  entry's tmdb_id.
  """

  use ExUnit.Case, async: true

  alias Mydia.Media.FranchiseEntry
  alias MydiaWeb.MediaLive.Show.AddConfigEvents

  describe "franchise_entry?/2" do
    test "matches a TMDB ref against a franchise entry sharing its id" do
      franchise = %{entries: [%FranchiseEntry{tmdb_id: 672}]}

      assert AddConfigEvents.franchise_entry?(franchise, {:tmdb, 672})
    end

    test "never matches a TVDB ref, even when the numeric id collides with a real entry" do
      franchise = %{entries: [%FranchiseEntry{tmdb_id: 672}]}

      refute AddConfigEvents.franchise_entry?(franchise, {:tvdb, 672})
    end

    test "false with no franchise loaded, regardless of provider" do
      refute AddConfigEvents.franchise_entry?(nil, {:tmdb, 672})
      refute AddConfigEvents.franchise_entry?(nil, {:tvdb, 672})
    end

    test "false for a TMDB id that is not in the franchise" do
      franchise = %{entries: [%FranchiseEntry{tmdb_id: 672}]}

      refute AddConfigEvents.franchise_entry?(franchise, {:tmdb, 999})
    end
  end
end
