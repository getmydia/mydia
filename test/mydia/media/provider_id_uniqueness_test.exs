defmodule Mydia.Media.ProviderIdUniquenessTest do
  @moduledoc """
  The index and the changeset have to agree on a name.

  `unique_constraint(:tmdb_id)` with no `:name` expects the index
  `media_items_tmdb_id_index`. Once the migration replaces that with
  `media_items_type_tmdb_id_index`, a bare call no longer matches and Ecto
  raises `Ecto.ConstraintError` instead of returning a changeset: a 500 where
  there used to be a form error. These tests fail loudly if the two drift apart
  again.
  """
  use Mydia.DataCase, async: false

  alias Mydia.Media

  describe "tmdb_id" do
    test "a movie and a tv show may share one" do
      id = System.unique_integer([:positive])

      assert {:ok, movie} =
               Media.create_media_item(%{
                 type: "movie",
                 title: "Cinder Lantern",
                 year: 2014,
                 tmdb_id: id
               })

      assert {:ok, show} =
               Media.create_media_item(
                 %{type: "tv_show", title: "Cinder Lantern", tmdb_id: id},
                 skip_episode_refresh: true
               )

      assert movie.tmdb_id == id
      assert show.tmdb_id == id
    end

    test "two tv shows may not, and the collision is a changeset error not a raise" do
      id = System.unique_integer([:positive])

      assert {:ok, _} =
               Media.create_media_item(
                 %{type: "tv_show", title: "Harrow Bay", tmdb_id: id},
                 skip_episode_refresh: true
               )

      assert {:error, changeset} =
               Media.create_media_item(
                 %{type: "tv_show", title: "Harrow Bay Redux", tmdb_id: id},
                 skip_episode_refresh: true
               )

      assert %{tmdb_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "tvdb_id" do
    test "a movie and a tv show may share one" do
      id = System.unique_integer([:positive])

      assert {:ok, movie} =
               Media.create_media_item(%{
                 type: "movie",
                 title: "Pale Orchard",
                 year: 2018,
                 tvdb_id: id
               })

      assert {:ok, show} =
               Media.create_media_item(
                 %{type: "tv_show", title: "Pale Orchard", tvdb_id: id},
                 skip_episode_refresh: true
               )

      assert movie.tvdb_id == id
      assert show.tvdb_id == id
    end

    test "two tv shows may not, and the collision is a changeset error not a raise" do
      id = System.unique_integer([:positive])

      assert {:ok, _} =
               Media.create_media_item(
                 %{type: "tv_show", title: "Vellum Coast", tvdb_id: id},
                 skip_episode_refresh: true
               )

      assert {:error, changeset} =
               Media.create_media_item(
                 %{type: "tv_show", title: "Vellum Coast Redux", tvdb_id: id},
                 skip_episode_refresh: true
               )

      assert %{tvdb_id: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
