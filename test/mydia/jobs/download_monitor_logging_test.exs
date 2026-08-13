defmodule Mydia.Jobs.DownloadMonitorLoggingTest do
  # async: false — this raises the *global* Logger level to :info so Logger macro
  # arguments are actually evaluated.
  #
  # The rest of the suite runs at :warning (config/test.exs), and `Logger.info/2`
  # is a macro that skips evaluating its arguments entirely when the level is
  # above the configured one. That is how a `Logger.info` referencing a
  # non-existent struct key reached production: green here, KeyError on prod
  # (config/prod.exs sets :info).
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import ExUnit.CaptureLog
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Events
  alias Mydia.Jobs.DownloadMonitor

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  describe "handle_missing/1 with info logging enabled" do
    test "marks a download missing without raising" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()
      download = download_fixture(%{media_item_id: media_item.id})

      capture_log(fn ->
        assert :ok = perform_job(DownloadMonitor, %{})
      end)

      updated = Downloads.get_download!(download.id)
      assert updated.error_message =~ "no longer configured in Mydia"
    end

    test "marks every missing download in the batch and emits an event for each" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      downloads =
        for n <- 1..3, do: download_fixture(%{media_item_id: media_item.id, title: "Grab #{n}"})

      capture_log(fn ->
        assert :ok = perform_job(DownloadMonitor, %{})
      end)

      # A raise inside the Enum.each over `missing` used to abort the pass after
      # the first row, so later downloads went unmarked and no event ever fired.
      for download <- downloads do
        assert Downloads.get_download!(download.id).error_message =~
                 "no longer configured in Mydia"
      end

      assert length(Events.list_events(type: "download.failed")) == 3
    end
  end

  describe "poll summary with info logging enabled" do
    test "reports the stall-update failure counter" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()
      download_fixture(%{media_item_id: media_item.id})

      log =
        capture_log(fn ->
          assert :ok = perform_job(DownloadMonitor, %{})
        end)

      assert log =~ "Download monitoring completed"
      assert log =~ "stall_update_failures"
    end
  end

  defp setup_runtime_config(download_clients) do
    config = %Mydia.Config.Schema{
      server: %Mydia.Config.Schema.Server{},
      database: %Mydia.Config.Schema.Database{},
      auth: %Mydia.Config.Schema.Auth{},
      media: %Mydia.Config.Schema.Media{},
      downloads: %Mydia.Config.Schema.Downloads{},
      logging: %Mydia.Config.Schema.Logging{},
      oban: %Mydia.Config.Schema.Oban{},
      download_clients: download_clients
    }

    previous = Application.get_env(:mydia, :runtime_config)
    Application.put_env(:mydia, :runtime_config, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :runtime_config)
        value -> Application.put_env(:mydia, :runtime_config, value)
      end
    end)
  end

  defp build_test_client_config(overrides \\ %{}) do
    defaults = %{
      name: "TestClient",
      type: :qbittorrent,
      enabled: true,
      priority: 1,
      host: "localhost",
      port: 8080,
      username: "admin",
      password: "admin",
      use_ssl: false,
      url_base: nil,
      category: nil,
      download_directory: nil
    }

    struct!(Mydia.Config.Schema.DownloadClient, Map.merge(defaults, overrides))
  end
end
