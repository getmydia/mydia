defmodule Mydia.Downloads.ClientTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Client.Error

  # Mock adapter implementation for testing the behaviour contract
  defmodule MockAdapter do
    @behaviour Client

    @impl true
    def supported_protocols, do: [:torrent]

    @impl true
    def test_connection(%{host: "valid.host"}) do
      {:ok, %{version: "v4.5.0", api_version: "2.8.19"}}
    end

    def test_connection(%{host: "invalid.host"}) do
      {:error, Error.connection_failed("Connection refused")}
    end

    @impl true
    def add_torrent(_config, {:magnet, "magnet:?xt=valid"}, _opts) do
      {:ok, "abc123def456"}
    end

    def add_torrent(_config, {:file, _contents}, opts) do
      category = Keyword.get(opts, :category)
      {:ok, "file-id-#{category}"}
    end

    def add_torrent(_config, {:url, _url}, _opts) do
      {:ok, "url-id"}
    end

    def add_torrent(_config, {:magnet, "magnet:?xt=invalid"}, _opts) do
      {:error, Error.invalid_torrent("Invalid magnet link")}
    end

    @impl true
    def get_status(_config, "valid-id") do
      {:ok,
       %{
         id: "valid-id",
         name: "Test Torrent",
         state: :downloading,
         progress: 45.5,
         download_speed: 1_234_567,
         upload_speed: 123_456,
         downloaded: 1_234_567_890,
         uploaded: 123_456_789,
         size: 2_345_678_901,
         eta: 3600,
         ratio: 1.5,
         save_path: "/downloads/test",
         added_at: ~U[2024-01-01 00:00:00Z],
         completed_at: nil
       }}
    end

    def get_status(_config, "invalid-id") do
      {:error, Error.not_found("Torrent not found")}
    end

    @impl true
    def list_torrents(_config, filter: :downloading) do
      {:ok,
       [
         %{
           id: "torrent-1",
           name: "Downloading Torrent",
           state: :downloading,
           progress: 45.5,
           download_speed: 1_000_000,
           upload_speed: 100_000,
           downloaded: 500_000_000,
           uploaded: 50_000_000,
           size: 1_000_000_000,
           eta: 500,
           ratio: 0.1,
           save_path: "/downloads",
           added_at: ~U[2024-01-01 00:00:00Z],
           completed_at: nil
         }
       ]}
    end

    def list_torrents(_config, _opts) do
      {:ok, []}
    end

    @impl true
    def remove_torrent(_config, "valid-id", _opts) do
      :ok
    end

    def remove_torrent(_config, "invalid-id", _opts) do
      {:error, Error.not_found("Torrent not found")}
    end

    @impl true
    def pause_torrent(_config, "valid-id") do
      :ok
    end

    def pause_torrent(_config, "invalid-id") do
      {:error, Error.not_found("Torrent not found")}
    end

    @impl true
    def resume_torrent(_config, "valid-id") do
      :ok
    end

    def resume_torrent(_config, "invalid-id") do
      {:error, Error.not_found("Torrent not found")}
    end
  end

  describe "behaviour contract - test_connection/1" do
    test "returns ok tuple with version info on success" do
      config = %{host: "valid.host", port: 8080}

      assert {:ok, %{version: version, api_version: api_version}} =
               MockAdapter.test_connection(config)

      assert is_binary(version)
      assert is_binary(api_version)
    end

    test "returns error tuple on connection failure" do
      config = %{host: "invalid.host", port: 8080}

      assert {:error, %Error{type: :connection_failed}} = MockAdapter.test_connection(config)
    end
  end

  describe "behaviour contract - add_torrent/3" do
    setup do
      config = %{
        type: :test,
        host: "localhost",
        port: 8080,
        username: "admin",
        password: "admin",
        use_ssl: false,
        options: %{}
      }

      {:ok, config: config}
    end

    test "accepts magnet link and returns client ID", %{config: config} do
      assert {:ok, client_id} = MockAdapter.add_torrent(config, {:magnet, "magnet:?xt=valid"}, [])
      assert is_binary(client_id)
    end

    test "accepts torrent file contents and returns client ID", %{config: config} do
      file_contents = <<1, 2, 3, 4>>

      assert {:ok, client_id} = MockAdapter.add_torrent(config, {:file, file_contents}, [])
      assert is_binary(client_id)
    end

    test "accepts torrent URL and returns client ID", %{config: config} do
      assert {:ok, client_id} =
               MockAdapter.add_torrent(config, {:url, "https://example.com/file.torrent"}, [])

      assert is_binary(client_id)
    end

    test "supports options like category and tags", %{config: config} do
      opts = [category: "movies", tags: ["hd", "action"], paused: true]

      assert {:ok, client_id} = MockAdapter.add_torrent(config, {:file, <<>>}, opts)
      assert client_id =~ "movies"
    end

    test "returns error for invalid torrent", %{config: config} do
      assert {:error, %Error{type: :invalid_torrent}} =
               MockAdapter.add_torrent(config, {:magnet, "magnet:?xt=invalid"}, [])
    end
  end

  describe "behaviour contract - get_status/2" do
    setup do
      config = %{host: "localhost", port: 8080}
      {:ok, config: config}
    end

    test "returns status map with all required fields", %{config: config} do
      assert {:ok, status} = MockAdapter.get_status(config, "valid-id")

      # Verify all required fields are present
      assert is_binary(status.id)
      assert is_binary(status.name)
      assert status.state in [:downloading, :seeding, :paused, :error, :completed, :checking]
      assert is_float(status.progress)
      assert is_integer(status.download_speed)
      assert is_integer(status.upload_speed)
      assert is_integer(status.downloaded)
      assert is_integer(status.uploaded)
      assert is_integer(status.size)
      assert is_integer(status.eta) or is_nil(status.eta)
      assert is_float(status.ratio)
      assert is_binary(status.save_path)
      assert %DateTime{} = status.added_at
      assert is_nil(status.completed_at) or match?(%DateTime{}, status.completed_at)
    end

    test "returns error when torrent not found", %{config: config} do
      assert {:error, %Error{type: :not_found}} = MockAdapter.get_status(config, "invalid-id")
    end
  end

  describe "behaviour contract - list_torrents/2" do
    setup do
      config = %{host: "localhost", port: 8080}
      {:ok, config: config}
    end

    test "returns list of status maps", %{config: config} do
      assert {:ok, torrents} = MockAdapter.list_torrents(config, [])
      assert is_list(torrents)
    end

    test "supports filter option", %{config: config} do
      assert {:ok, [torrent]} = MockAdapter.list_torrents(config, filter: :downloading)
      assert torrent.state == :downloading
    end

    test "returned torrents have proper structure", %{config: config} do
      {:ok, [torrent | _]} = MockAdapter.list_torrents(config, filter: :downloading)

      # Verify structure matches status_map type
      assert is_binary(torrent.id)
      assert is_binary(torrent.name)
      assert is_atom(torrent.state)
      assert is_float(torrent.progress)
    end
  end

  describe "behaviour contract - remove_torrent/3" do
    setup do
      config = %{host: "localhost", port: 8080}
      {:ok, config: config}
    end

    test "returns ok on successful removal", %{config: config} do
      assert :ok = MockAdapter.remove_torrent(config, "valid-id", [])
    end

    test "supports delete_files option", %{config: config} do
      assert :ok = MockAdapter.remove_torrent(config, "valid-id", delete_files: true)
    end

    test "returns error when torrent not found", %{config: config} do
      assert {:error, %Error{type: :not_found}} =
               MockAdapter.remove_torrent(config, "invalid-id", [])
    end
  end

  describe "behaviour contract - pause_torrent/2" do
    setup do
      config = %{host: "localhost", port: 8080}
      {:ok, config: config}
    end

    test "returns ok on successful pause", %{config: config} do
      assert :ok = MockAdapter.pause_torrent(config, "valid-id")
    end

    test "returns error when torrent not found", %{config: config} do
      assert {:error, %Error{type: :not_found}} = MockAdapter.pause_torrent(config, "invalid-id")
    end
  end

  describe "behaviour contract - resume_torrent/2" do
    setup do
      config = %{host: "localhost", port: 8080}
      {:ok, config: config}
    end

    test "returns ok on successful resume", %{config: config} do
      assert :ok = MockAdapter.resume_torrent(config, "valid-id")
    end

    test "returns error when torrent not found", %{config: config} do
      assert {:error, %Error{type: :not_found}} =
               MockAdapter.resume_torrent(config, "invalid-id")
    end
  end

  describe "config type" do
    test "config has required fields" do
      config = %{
        type: :qbittorrent,
        host: "localhost",
        port: 8080,
        username: "admin",
        password: "secret",
        use_ssl: false,
        options: %{}
      }

      # Verify the config structure
      assert is_atom(config.type)
      assert is_binary(config.host)
      assert is_integer(config.port)
      assert is_binary(config.username)
      assert is_binary(config.password)
      assert is_boolean(config.use_ssl)
      assert is_map(config.options)
    end
  end

  describe "torrent_state type" do
    test "all valid states are atoms" do
      valid_states = [:downloading, :seeding, :paused, :error, :completed, :checking]

      for state <- valid_states do
        assert is_atom(state)
      end
    end
  end
end
