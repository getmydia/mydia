defmodule Mydia.PlexPluginCase do
  @moduledoc """
  Runs the real bundled `plex.wasm` against two fakes: Bypass for plex.tv, and
  `Mydia.FakePlexServer` for a Plex Media Server. The instance's `plex_tv_base`
  setting points the guest at the first; the second is the instance's approved
  endpoint.

  Every user is async: false. A real pool starts under the app-wide
  PoolRegistry and the guest reads rows the test seeds.
  """

  use ExUnit.CaseTemplate

  alias Mydia.Accounts.Scope
  alias Mydia.FakePlexServer
  alias Mydia.Media
  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @slug "plex"

  @grants %{
    "events:subscribe" => ["media_file.imported", "playback.finished"],
    "net:http" => ["127.0.0.1"],
    "state:kv" => [],
    "data:read" => ["playback_progress"],
    "surfaces:write" => ["playback:watched"],
    "users:connections" => [],
    "schedule:interval" => []
  }

  using do
    quote do
      use Mydia.DataCase, async: false

      import Mydia.AccountsFixtures
      import Mydia.PlexPluginCase

      alias Mydia.FakePlexServer
      alias Mydia.Playback
      alias Mydia.Plugins
      alias Mydia.Plugins.AccountLinks
      alias Mydia.Plugins.Instances
      alias Mydia.Plugins.Kv

      # Registered here, after DataCase's own setup, so the sandbox is checked
      # out before the setup below writes rows.
      setup :plex_setup
    end
  end

  @doc false
  def plex_setup(_context) do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    plex_tv = Bypass.open()
    server = FakePlexServer.open()
    manifest = Jason.decode!(File.read!(Application.app_dir(:mydia, "priv/plugins/plex.json")))

    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Plex",
        version: manifest["version"],
        source_url: "test",
        manifest: manifest,
        settings: %{},
        granted_capabilities: @grants,
        enabled: true
      })

    # Built from the real manifest so the registered plugin carries `setup: true`
    # (invoke_setup/3 and invoke_check_health/2 refuse without it),
    # `multi_instance: true` and the `X-Plex-Token: {token}` auth header that
    # link-request injects. Inline delivery so media_file.imported runs in the
    # test process rather than through the Oban durable path (Oban is not
    # started in test).
    {:ok, parsed} = Manifest.parse(manifest)

    {:ok, _} =
      Registry.register(
        @slug,
        Plugin.from_manifest(parsed,
          granted_capabilities: @grants,
          enabled: true,
          delivery: :inline
        )
      )

    imports =
      HostFunctions.imports_for(@slug,
        allow_private: true,
        resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
      )

    bytes = File.read!(Application.app_dir(:mydia, "priv/plugins/plex.wasm"))
    {:ok, _pid} = Host.start_plugin(@slug, bytes, imports: imports)
    on_exit(fn -> Host.stop_plugin(@slug) end)
    # Registered last so it runs first: a late playback event then finds no
    # plugin, instead of a registered plugin whose pool is already gone.
    on_exit(fn -> Registry.unregister(@slug) end)

    server_url = "http://127.0.0.1:#{server.port}"
    tv_base = "http://127.0.0.1:#{plex_tv.port}/api/v2"

    {:ok, instance} =
      Instances.create(@slug, %{
        name: "Den",
        settings: %{
          "url" => server_url,
          "sync_watched" => "on",
          "sync_watched_direction" => "bidirectional",
          "plex_tv_base" => tv_base
        }
      })

    {:ok, instance} =
      Instances.approve_endpoints(instance, [
        %{"scheme" => "http", "host" => "127.0.0.1", "port" => server.port}
      ])

    {:ok, _} = AccountLinks.put_credential(instance.id, :owner, "owner-token")

    %{
      plex_tv: plex_tv,
      server: server,
      instance: instance,
      server_url: server_url,
      tv_base: tv_base
    }
  end

  @doc """
  Links every `{user, token}` pair to its own Plex profile in one call, since
  `replace_user_links/3` makes the instance's links exactly the list given.
  Returns the links in the same order.
  """
  def link_users!(instance, pairs) do
    mappings =
      for {user, _token} <- pairs,
          do: %{
            remote_account_id: "uuid-#{user.id}",
            remote_username: user.username,
            user_id: user.id
          }

    {:ok, links} = AccountLinks.replace_user_links(instance.id, mappings, :admin_mapped)

    for {user, token} <- pairs do
      link = Enum.find(links, &(&1.user_id == user.id))
      :ok = AccountLinks.set_token(link.id, token)
      link
    end
  end

  def link_user!(instance, user, token), do: instance |> link_users!([{user, token}]) |> hd()

  @doc "A fictional movie with a unique tmdb id."
  def movie!(title) do
    {:ok, item} =
      Media.create_media_item(Scope.unrestricted(), %{
        title: title,
        type: "movie",
        year: 2024,
        tmdb_id: System.unique_integer([:positive])
      })

    item
  end

  @doc "A fictional show with one episode, keyed by tvdb id."
  def show_with_episode!(tvdb, season, episode) do
    {:ok, show} =
      Media.create_media_item(
        Scope.unrestricted(),
        %{title: "Harbor Lights #{tvdb}", type: "tv_show", year: 2024, tvdb_id: tvdb},
        skip_episode_refresh: true
      )

    {:ok, ep} =
      Media.create_episode(%{
        media_item_id: show.id,
        season_number: season,
        episode_number: episode,
        title: "Chapter #{episode}"
      })

    {show, ep}
  end

  @doc "Plex's paging offset, which the guest sends as a request header."
  def container_start(conn) do
    conn
    |> Plug.Conn.get_req_header("x-plex-container-start")
    |> List.first("0")
    |> String.to_integer()
  end

  def token(conn), do: conn |> Plug.Conn.get_req_header("x-plex-token") |> List.first()

  def query(conn), do: Plug.Conn.fetch_query_params(conn).query_params

  def json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  @doc "One movie section (key 1) and one show section (key 2), for any token."
  def stub_sections(server) do
    FakePlexServer.stub(server, "GET", "/library/sections", fn conn ->
      json(conn, 200, %{
        "MediaContainer" => %{
          "Directory" => [
            %{"key" => "1", "type" => "movie", "title" => "Films"},
            %{"key" => "2", "type" => "show", "title" => "Series"}
          ]
        }
      })
    end)
  end

  def stub_empty_shows(server) do
    FakePlexServer.stub(server, "GET", "/library/sections/2/all", fn conn ->
      json(conn, 200, %{"MediaContainer" => %{}})
    end)
  end

  def movie_json(rk, tmdb, extra \\ %{}) do
    Map.merge(
      %{"ratingKey" => rk, "type" => "movie", "Guid" => [%{"id" => "tmdb://#{tmdb}"}]},
      extra
    )
  end

  @doc """
  Seeds the store as a completed crawl of one movie. Task 18 migrates no
  crawl, so a migrated instance's real first tick crawls first; this skips it.
  """
  def seed_crawled_movie!(instance, movie, rk) do
    now = System.system_time(:second)

    {:ok, _} =
      Mydia.Plugins.Kv.set(
        instance.id,
        "crawl/state",
        Jason.encode!(%{
          section_keys: [],
          section_index: 0,
          offset: 0,
          started_at: now,
          completed_at: now,
          last_completed_at: now
        })
      )

    {:ok, _} =
      Mydia.Plugins.Kv.set(
        instance.id,
        "map/#{rk}",
        Jason.encode!(%{
          kind: "movie",
          imdb: nil,
          tmdb: movie.tmdb_id,
          tvdb: nil,
          season: nil,
          episode: nil,
          show_tmdb: nil,
          show_tvdb: nil
        })
      )

    {:ok, _} = Mydia.Plugins.Kv.set(instance.id, "rev/movie/tmdb/#{movie.tmdb_id}", ~s("#{rk}"))
    now
  end
end
