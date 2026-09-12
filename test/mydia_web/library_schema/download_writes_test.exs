defmodule MydiaWeb.LibrarySchema.DownloadWritesTest do
  # async: false: registers an adapter in the global download-client Registry,
  # as test/mydia/downloads_test.exs does.
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.LibraryApi.Principal
  alias Mydia.Repo

  @moduletag :capture_log

  @admin %Principal{role: "admin", source: :env}

  defmodule RemovingAdapter do
    @moduledoc "A download client that accepts every request, so cancel can succeed."
    @behaviour Mydia.Downloads.Client

    @impl true
    def supported_protocols, do: [:torrent]

    @impl true
    def test_connection(_config), do: {:ok, %{version: "1.0.0", api_version: "1.0"}}

    @impl true
    def add_torrent(_config, _torrent, _opts), do: {:ok, "removing-adapter-id"}

    @impl true
    def get_status(_config, _client_id), do: {:ok, %{}}

    @impl true
    def list_torrents(_config, _opts), do: {:ok, []}

    @impl true
    def remove_torrent(_config, _client_id, _opts), do: :ok

    @impl true
    def pause_torrent(_config, _client_id), do: :ok

    @impl true
    def resume_torrent(_config, _client_id), do: :ok
  end

  setup do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    original = Registry.get_adapter(:qbittorrent)

    Registry.register(:qbittorrent, RemovingAdapter)

    on_exit(fn ->
      case original do
        {:ok, adapter} -> Registry.register(:qbittorrent, adapter)
        {:error, _} -> Registry.unregister(:qbittorrent)
      end
    end)

    user = user_fixture()

    download_client_config_fixture(%{
      name: "api-test-client",
      type: "qbittorrent",
      enabled: true,
      host: "localhost",
      port: 8080,
      updated_by_id: user.id
    })

    :ok
  end

  defp run(document, variables) do
    Absinthe.run(document, MydiaWeb.LibrarySchema,
      variables: variables,
      context: %{principal: @admin}
    )
  end

  @cancel """
  mutation C($id: ID!) { cancelDownload(id: $id) { removedId userErrors { field code } } }
  """

  @reject """
  mutation R($id: ID!, $days: Int) {
    rejectRelease(id: $id, blocklistDays: $days) { removedId userErrors { field code } }
  }
  """

  describe "cancelDownload" do
    test "removes the download from its client and the queue" do
      item = media_item_fixture()
      download = download_fixture(%{media_item_id: item.id, download_client: "api-test-client"})

      assert {:ok, %{data: %{"cancelDownload" => payload}}} = run(@cancel, %{"id" => download.id})

      assert payload == %{"removedId" => download.id, "userErrors" => []}
      refute Repo.get(Download, download.id)
    end

    test "a client that is not configured is CLIENT_UNAVAILABLE and keeps the row" do
      item = media_item_fixture()
      download = download_fixture(%{media_item_id: item.id, download_client: "gone-client"})

      assert {:ok, %{data: %{"cancelDownload" => payload}}} = run(@cancel, %{"id" => download.id})

      assert payload["removedId"] == nil
      assert [%{"code" => "CLIENT_UNAVAILABLE", "field" => ["id"]}] = payload["userErrors"]
      assert Repo.get(Download, download.id)
    end

    test "an id that names nothing is NOT_FOUND" do
      assert {:ok, %{data: %{"cancelDownload" => payload}}} =
               run(@cancel, %{"id" => Ecto.UUID.generate()})

      assert [%{"code" => "NOT_FOUND", "field" => ["id"]}] = payload["userErrors"]
    end
  end

  describe "rejectRelease" do
    test "blocklists the release, removes the row and searches again" do
      show = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: show.id,
          indexer: "1337x",
          metadata: %{"guid" => "api-guid"}
        })

      assert {:ok, %{data: %{"rejectRelease" => payload}}} = run(@reject, %{"id" => download.id})

      assert payload == %{"removedId" => download.id, "userErrors" => []}
      assert Blacklists.blacklisted?("1337x", "api-guid")
      refute Repo.get(Download, download.id)

      assert_enqueued(
        worker: Mydia.Jobs.TVShowSearch,
        args: %{"mode" => "show", "media_item_id" => show.id}
      )
    end

    test "blocklistDays sets how long the release stays blocked" do
      item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: item.id,
          indexer: "1337x",
          metadata: %{"guid" => "ttl-api-guid"}
        })

      assert {:ok, %{data: %{"rejectRelease" => %{"userErrors" => []}}}} =
               run(@reject, %{"id" => download.id, "days" => 7})

      row = Repo.get_by!(ReleaseBlacklist, indexer: "1337x", guid: "ttl-api-guid")
      expected = DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)
      assert abs(DateTime.diff(row.expires_at, expected, :second)) < 60
    end

    test "a blocklistDays below 1 is INVALID_INPUT and changes nothing" do
      item = media_item_fixture()
      download = download_fixture(%{media_item_id: item.id})

      assert {:ok, %{data: %{"rejectRelease" => payload}}} =
               run(@reject, %{"id" => download.id, "days" => 0})

      assert [%{"code" => "INVALID_INPUT", "field" => ["blocklistDays"]}] = payload["userErrors"]
      assert Repo.get(Download, download.id)
    end
  end
end
