defmodule Mydia.E2E.NzbgetImportTest do
  @moduledoc """
  E2E tests for the NZBGet download import pipeline.

  These tests require the mock-nzbget service to be running:
    docker compose -f compose.test.yml --profile usenet up -d

  Tests are tagged with :e2e and :nzbget so they can be excluded from
  normal test runs: mix test --exclude e2e
  """

  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Downloads
  alias Mydia.Jobs.{DownloadMonitor, MediaImport}
  alias Mydia.Settings
  alias Mydia.Test.UsenetE2EHelpers

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  @moduletag :e2e
  @moduletag :nzbget

  setup do
    unless UsenetE2EHelpers.nzbget_available?() do
      :ok
    else
      UsenetE2EHelpers.reset_mock_services()

      uri = URI.parse(UsenetE2EHelpers.nzbget_url())

      {:ok, client_config} =
        Settings.create_download_client_config(%{
          name: "MockNZBGet",
          type: :nzbget,
          host: uri.host,
          port: uri.port,
          username: "nzbget",
          password: "tegbzn6789",
          enabled: true,
          priority: 1
        })

      {:ok, client_config: client_config, nzbget_available: true}
    end
  end

  describe "full NZBGet import pipeline" do
    @tag timeout: 30_000
    test "detects completion and imports files", context do
      unless context[:nzbget_available] do
        IO.puts(
          "SKIP: Mock NZBGet not available. Run: docker compose -f compose.test.yml --profile usenet up -d"
        )
      else
        {:ok, _library_path} =
          Settings.create_library_path(%{
            path: "/downloads/library",
            type: :movies,
            monitored: true
          })

        {:ok, nzb_id, dest_dir} =
          UsenetE2EHelpers.inject_nzbget_completed(
            name: "Test.Movie.2024.720p.WEB-DL",
            dest_dir: "/downloads/completed/Test.Movie.2024.720p.WEB-DL",
            files: [
              %{
                path:
                  "/downloads/completed/Test.Movie.2024.720p.WEB-DL/Test.Movie.2024.720p.WEB-DL.mkv",
                size: 2048
              }
            ]
          )

        media_item = media_item_fixture(%{type: "movie", title: "Test Movie", year: 2024})

        download =
          download_fixture(%{
            media_item_id: media_item.id,
            download_client: "MockNZBGet",
            download_client_id: "#{nzb_id}",
            title: "Test.Movie.2024.720p.WEB-DL"
          })

        assert :ok = perform_job(DownloadMonitor, %{})

        updated = Downloads.get_download!(download.id)
        assert updated.completed_at != nil
        assert updated.save_path == dest_dir

        result =
          perform_job(MediaImport, %{
            "download_id" => download.id,
            "save_path" => dest_dir,
            "use_hardlinks" => false,
            "move_files" => true
          })

        assert {:ok, _} = result

        final = Downloads.get_download!(download.id)
        assert final.imported_at != nil
      end
    end
  end
end
