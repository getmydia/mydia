defmodule Mydia.Jobs.EpisodeFetchTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Ecto.Query
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Events.Event
  alias Mydia.Jobs.EpisodeFetch
  alias Mydia.Media
  alias Mydia.Media.Episodes

  defp tv_item do
    tvdb_id = System.unique_integer([:positive])

    {:ok, item} =
      Media.create_media_item(
        Scope.system(),
        %{
          type: "tv_show",
          title: "Harbor Lights #{tvdb_id}",
          year: 2023,
          tvdb_id: tvdb_id,
          metadata_source: :tvdb,
          monitored: true
        },
        episodes: :skip
      )

    item
  end

  defp relay_config(bypass, item, mode \\ :ok) do
    series_id = item.tvdb_id
    season_ids = %{1 => series_id * 10 + 1, 2 => series_id * 10 + 2}

    case mode do
      :error ->
        Bypass.stub(bypass, "GET", "/tvdb/series/#{series_id}/extended", fn conn ->
          Plug.Conn.resp(conn, 500, "boom")
        end)

      :ok ->
        Bypass.stub(bypass, "GET", "/tvdb/series/#{series_id}/extended", fn conn ->
          json(conn, %{
            "data" => %{
              "id" => series_id,
              "name" => item.title,
              "overview" => "x",
              "firstAired" => "2023-01-01",
              "status" => %{"name" => "Continuing"},
              "genres" => [],
              "seasons" =>
                for {n, sid} <- season_ids do
                  %{
                    "id" => sid,
                    "number" => n,
                    "name" => "Season #{n}",
                    "type" => %{"type" => "official"},
                    "episodeCount" => 1
                  }
                end
            }
          })
        end)

        for {n, sid} <- season_ids do
          ep_id = sid * 10

          Bypass.stub(bypass, "GET", "/tvdb/seasons/#{sid}/extended", fn conn ->
            json(conn, %{
              "data" => %{
                "id" => sid,
                "number" => n,
                "name" => "Season #{n}",
                "episodes" => [
                  %{
                    "id" => ep_id,
                    "seasonNumber" => n,
                    "number" => 1,
                    "name" => "Chapter #{n}",
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
        end
    end

    %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }
  end

  defp run(args, config), do: EpisodeFetch.run(EpisodeFetch.Args.parse(args), config)

  test "creates episodes and records the event" do
    item = tv_item()
    config = relay_config(Bypass.open(), item)

    assert :ok = run(%{"media_item_id" => item.id}, config)
    assert Episodes.list_episodes(Scope.system(), item.id) != []

    assert Repo.exists?(
             from e in Event,
               where: e.type == "media_item.episodes_refreshed" and e.resource_id == ^item.id
           )
  end

  test "applies season_monitoring first" do
    item = tv_item()
    config = relay_config(Bypass.open(), item)

    assert :ok = run(%{"media_item_id" => item.id, "season_monitoring" => "first"}, config)

    episodes = Episodes.list_episodes(Scope.system(), item.id)
    assert Enum.any?(episodes, &(&1.season_number == 2))

    for ep <- episodes do
      assert ep.monitored == (ep.season_number == 1)
    end
  end

  test "queues TVShowSearch only when search_on_add" do
    item = tv_item()
    config = relay_config(Bypass.open(), item)

    assert :ok = run(%{"media_item_id" => item.id}, config)
    refute_enqueued(worker: Mydia.Jobs.TVShowSearch)

    assert :ok = run(%{"media_item_id" => item.id, "search_on_add" => true}, config)

    assert_enqueued(
      worker: Mydia.Jobs.TVShowSearch,
      args: %{"mode" => "show", "media_item_id" => item.id}
    )
  end

  test "relay failure returns error and queues no search" do
    item = tv_item()
    config = relay_config(Bypass.open(), item, :error)

    assert {:error, _} = run(%{"media_item_id" => item.id, "search_on_add" => true}, config)
    refute_enqueued(worker: Mydia.Jobs.TVShowSearch)
  end

  test "discards a deleted item or a movie" do
    assert {:discard, :not_found} =
             perform_job(EpisodeFetch, %{"media_item_id" => Ecto.UUID.generate()})

    movie = media_item_fixture(%{type: "movie", title: "A Quiet Harbor", year: 2020})
    assert {:discard, :not_found} = perform_job(EpisodeFetch, %{"media_item_id" => movie.id})
  end

  test "enqueue is unique per media item" do
    item = tv_item()

    assert {:ok, _} = EpisodeFetch.enqueue(item, [])
    assert {:ok, _} = EpisodeFetch.enqueue(item, [])
    assert [_] = all_enqueued(worker: EpisodeFetch)
  end

  test "pending? tracks job state" do
    item = tv_item()
    refute EpisodeFetch.pending?(item.id)

    {:ok, job} = EpisodeFetch.enqueue(item, [])
    assert EpisodeFetch.pending?(item.id)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])
    refute EpisodeFetch.pending?(item.id)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
