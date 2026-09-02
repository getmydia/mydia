defmodule MydiaWeb.DiscoverLive.AutoSearchTest do
  @moduledoc """
  Covers the bug this task fixes: adding a title from Discover never queued an
  indexer search, because `handle_add_media_to_library/5` had no idea
  `search_on_add` existed. `AddDefaults.resolve/3` (Task 3) now resolves the
  setting; this exercises the helper actually acting on it.

  Oban runs `testing: :manual` in `config/test.exs` (see `config/test.exs` and
  `test/README.md`), so jobs are inserted but never executed, and
  `Oban.Testing`'s assertions work against the inserted row. Matches
  `test/mydia/search_test.exs`, which asserts on `worker:` and `args:` rather
  than a bare count, so a job some unrelated code enqueues cannot make this
  pass.
  """

  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.SettingsFixtures

  alias Mydia.Config.Schema
  alias Mydia.Media.AddDefaults
  alias MydiaWeb.Live.Helpers.MediaAddHelpers

  defp config(overrides) do
    base = Schema.defaults()
    %{base | media: struct(base.media, overrides)}
  end

  defp relay_config(bypass) do
    %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }
  end

  defp stub_tmdb_movie(bypass, id, title) do
    body = %{
      "id" => id,
      "title" => title,
      "release_date" => "2021-03-04",
      "poster_path" => "/poster.jpg",
      "overview" => "x",
      "credits" => %{"cast" => [], "crew" => []},
      "genres" => []
    }

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  setup do
    library_path_fixture(%{type: :movies})
    :ok
  end

  test "an add with search_on_add true queues a search" do
    defaults = AddDefaults.resolve(nil, :movie, config: config(%{auto_search_on_add: true}))
    assert defaults.search_on_add == true

    bypass = Bypass.open()
    provider_id = System.unique_integer([:positive])
    stub_tmdb_movie(bypass, provider_id, "The Uncharted Reef")

    {:ok, media_item, _map} =
      MediaAddHelpers.handle_add_media_to_library(
        {:tmdb, provider_id},
        :movie,
        %{},
        relay_config(bypass),
        Keyword.put(AddDefaults.to_add_opts(defaults), :search_on_add, true)
      )

    assert_enqueued(
      worker: Mydia.Jobs.MovieSearch,
      args: %{mode: "specific", media_item_id: media_item.id}
    )
  end

  test "an add with search_on_add false queues nothing" do
    bypass = Bypass.open()
    provider_id = System.unique_integer([:positive])
    stub_tmdb_movie(bypass, provider_id, "A Lantern for Ghosts")

    defaults = AddDefaults.resolve(nil, :movie, config: config(%{}))

    {:ok, media_item, _map} =
      MediaAddHelpers.handle_add_media_to_library(
        {:tmdb, provider_id},
        :movie,
        %{},
        relay_config(bypass),
        Keyword.put(AddDefaults.to_add_opts(defaults), :search_on_add, false)
      )

    refute_enqueued(worker: Mydia.Jobs.MovieSearch, args: %{media_item_id: media_item.id})
  end
end
