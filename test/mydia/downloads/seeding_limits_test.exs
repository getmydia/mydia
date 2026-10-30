defmodule Mydia.Downloads.SeedingLimitsTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.Client.{Error, Registry}
  alias Mydia.Downloads.{Queue, SeedingLimits}
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.TrackerTerms

  defmodule LimitsAdapter do
    @behaviour Mydia.Downloads.Client

    defp notify(message) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil), do: send(pid, message)
    end

    @impl true
    def set_share_limits(_config, client_id, limits) do
      notify({:set_share_limits, client_id, limits})
      :persistent_term.get({__MODULE__, :result}, :ok)
    end

    @impl true
    def add_torrent(_config, _torrent, _opts), do: {:ok, "limits-id"}
    @impl true
    def supported_protocols, do: [:torrent]
    @impl true
    def test_connection(_config), do: {:ok, %{version: "1.0.0", api_version: "1.0"}}
    @impl true
    def get_status(_config, _client_id), do: {:error, Error.not_found("missing")}
    @impl true
    def list_torrents(_config, _opts), do: {:ok, []}
    @impl true
    def remove_torrent(_config, _client_id, _opts), do: :ok
    @impl true
    def pause_torrent(_config, _client_id), do: :ok
    @impl true
    def resume_torrent(_config, _client_id), do: :ok
  end

  defmodule NoLimitsAdapter do
    def supported_protocols, do: [:torrent]
  end

  setup do
    :persistent_term.put({LimitsAdapter, :pid}, self())

    on_exit(fn ->
      :persistent_term.erase({LimitsAdapter, :pid})
      :persistent_term.erase({LimitsAdapter, :result})
    end)

    :ok
  end

  @terms %TrackerTerms{private?: true, minimum_ratio: 1.0, minimum_seed_time: 3600}

  describe "push/4" do
    test "sends the ratio and seed time" do
      assert :ok = SeedingLimits.push(LimitsAdapter, %{}, "abc", @terms)
      assert_received {:set_share_limits, "abc", %{ratio: 1.0, seed_time: 3600}}
    end

    test "skips terms that set neither" do
      assert :skipped = SeedingLimits.push(LimitsAdapter, %{}, "abc", nil)

      assert :skipped =
               SeedingLimits.push(LimitsAdapter, %{}, "abc", %TrackerTerms{private?: true})

      refute_received {:set_share_limits, _, _}
    end

    test "is unsupported for an adapter without the callback" do
      assert :unsupported = SeedingLimits.push(NoLimitsAdapter, %{}, "abc", @terms)
    end

    test "logs and returns a client error without raising" do
      :persistent_term.put({LimitsAdapter, :result}, {:error, Error.api_error("nope")})

      log =
        capture_log(fn ->
          assert {:error, %Error{}} = SeedingLimits.push(LimitsAdapter, %{}, "abc", @terms)
        end)

      assert log =~ "Could not push tracker share limits"
    end
  end

  describe "at grab" do
    setup do
      previous = Registry.lookup(:qbittorrent)
      Registry.register(:qbittorrent, LimitsAdapter)
      on_exit(fn -> if previous, do: Registry.register(:qbittorrent, previous) end)

      download_client_config_fixture(%{name: "limits-client", type: "qbittorrent", enabled: true})
      :ok
    end

    defp search_result(terms) do
      %SearchResult{
        title: "Velvet.Orchard.2031.1080p.WEB-DL",
        indexer: "Velvet Lantern",
        download_url: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
        size: 1_000,
        seeders: 10,
        leechers: 1,
        download_protocol: :torrent,
        terms: terms
      }
    end

    test "the tracker's limits reach the client" do
      assert {:ok, _config, "limits-id", _type} =
               Queue.select_and_add_to_client(search_result(@terms), [])

      assert_received {:set_share_limits, "limits-id", %{ratio: 1.0, seed_time: 3600}}
    end

    test "a failed push does not fail the grab" do
      :persistent_term.put({LimitsAdapter, :result}, {:error, Error.api_error("nope")})

      capture_log(fn ->
        assert {:ok, _config, "limits-id", _type} =
                 Queue.select_and_add_to_client(search_result(@terms), [])
      end)
    end

    test "a release without terms pushes nothing" do
      assert {:ok, _config, "limits-id", _type} =
               Queue.select_and_add_to_client(search_result(nil), [])

      refute_received {:set_share_limits, _, _}
    end
  end
end
