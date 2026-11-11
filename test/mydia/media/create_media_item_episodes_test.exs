defmodule Mydia.Media.CreateMediaItemEpisodesTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.Episodes

  defp tv_attrs do
    tvdb_id = System.unique_integer([:positive])

    %{
      type: "tv_show",
      title: "Harbor Lights #{tvdb_id}",
      year: 2023,
      tvdb_id: tvdb_id,
      metadata_source: :tvdb,
      monitored: true
    }
  end

  defp add_show(attrs, opts), do: Media.create_media_item(Scope.system(), attrs, opts)

  defp relay_config(bypass, item_attrs) do
    series_id = item_attrs.tvdb_id
    season_id = series_id * 10 + 1
    ep_id = season_id * 10

    Bypass.stub(bypass, "GET", "/tvdb/series/#{series_id}/extended", fn conn ->
      json(conn, %{
        "data" => %{
          "id" => series_id,
          "name" => item_attrs.title,
          "overview" => "x",
          "firstAired" => "2023-01-01",
          "status" => %{"name" => "Continuing"},
          "genres" => [],
          "seasons" => [
            %{
              "id" => season_id,
              "number" => 1,
              "name" => "Season 1",
              "type" => %{"type" => "official"}
            }
          ]
        }
      })
    end)

    Bypass.stub(bypass, "GET", "/tvdb/seasons/#{season_id}/extended", fn conn ->
      json(conn, %{
        "data" => %{
          "id" => season_id,
          "number" => 1,
          "name" => "Season 1",
          "episodes" => [
            %{
              "id" => ep_id,
              "seasonNumber" => 1,
              "number" => 1,
              "name" => "Chapter 1",
              "overview" => "o",
              "aired" => "2023-01-08",
              "runtime" => 40
            }
          ]
        }
      })
    end)

    Bypass.stub(bypass, "GET", "/tvdb/episodes/#{ep_id}/extended", fn conn ->
      json(conn, %{"data" => %{"id" => ep_id, "translations" => %{}}})
    end)

    %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp episode_count(item), do: length(Episodes.list_episodes(Scope.system(), item.id))

  test "default enqueues EpisodeFetch and creates no episodes" do
    {:ok, item} = add_show(tv_attrs(), [])

    assert_enqueued(
      worker: Mydia.Jobs.EpisodeFetch,
      args: %{"media_item_id" => item.id, "season_monitoring" => "all"}
    )

    # EpisodeFetch.enqueue/2 leaves a false search_on_add out of the args.
    [job] = all_enqueued(worker: Mydia.Jobs.EpisodeFetch)
    refute Map.has_key?(job.args, "search_on_add")

    assert episode_count(item) == 0
  end

  test "forwards season_monitoring and search_on_add" do
    {:ok, item} = add_show(tv_attrs(), season_monitoring: "latest", search_on_add: true)

    assert_enqueued(
      worker: Mydia.Jobs.EpisodeFetch,
      args: %{
        "media_item_id" => item.id,
        "season_monitoring" => "latest",
        "search_on_add" => true
      }
    )
  end

  test ":skip enqueues nothing" do
    {:ok, item} = add_show(tv_attrs(), episodes: :skip)

    refute_enqueued(worker: Mydia.Jobs.EpisodeFetch)
    assert episode_count(item) == 0
  end

  test ":inline fetches before returning" do
    attrs = tv_attrs()
    config = relay_config(Bypass.open(), attrs)

    {:ok, item} = add_show(attrs, episodes: :inline, config: config)

    assert episode_count(item) > 0
    refute_enqueued(worker: Mydia.Jobs.EpisodeFetch)
  end

  test ":config without :episodes stays inline" do
    attrs = tv_attrs()
    config = relay_config(Bypass.open(), attrs)

    {:ok, item} = add_show(attrs, config: config)

    assert episode_count(item) > 0
    refute_enqueued(worker: Mydia.Jobs.EpisodeFetch)
  end

  test "movies never enqueue" do
    {:ok, _item} =
      add_show(%{type: "movie", title: "Quiet Harbor", year: 2022, monitored: true}, [])

    refute_enqueued(worker: Mydia.Jobs.EpisodeFetch)
  end

  test "unknown value raises" do
    assert_raise ArgumentError, fn -> add_show(tv_attrs(), episodes: :later) end
  end

  test "skip_episode_refresh is no longer honoured" do
    {:ok, item} = add_show(tv_attrs(), skip_episode_refresh: true)

    assert_enqueued(worker: Mydia.Jobs.EpisodeFetch, args: %{"media_item_id" => item.id})
  end
end
