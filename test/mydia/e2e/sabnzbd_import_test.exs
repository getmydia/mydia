defmodule Mydia.E2E.SabnzbdImportTest do
  @moduledoc """
  E2E tests for the SABnzbd download import pipeline.

  These tests require the mock-sabnzbd service to be running:
    docker compose -f compose.test.yml --profile usenet up -d

  Tests are tagged with :e2e and :sabnzbd so they can be excluded from
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
  @moduletag :sabnzbd

  setup do
    unless UsenetE2EHelpers.sabnzbd_available?() do
      {:skip, "Mock SABnzbd not available. Run: docker compose -f compose.test.yml --profile usenet up -d"}
    else
      UsenetE2EHelpers.reset_mock_services()

      uri = URI.parse(UsenetE2EHelpers.sabnzbd_url())

      {:ok, client_config} =
        Settings.create_download_client_config(%{
          name: "MockSABnzbd",
          type: :sabnzbd,
          host: uri.host,
          port: uri.port,
          enabled: true,
          priority: 1,
          options: %{api_key: "test-api-key"}
        })

      {:ok, client_config: client_config, sabnzbd_available: true}
    end
  end

  describe "full SABnzbd import pipeline" do
    @tag timeout: 30_000
    test "detects completion and imports files" do
      {:ok, _library_path} =
        Settings.create_library_path(%{
          path: "/downloads/library",
          type: :movies,
          monitored: true
        })

      {:ok, nzo_id, save_path} =
        UsenetE2EHelpers.inject_sabnzbd_completed(
          filename: "Test.Movie.2024.1080p.WEB-DL",
          storage: "/downloads/completed/Test.Movie.2024.1080p.WEB-DL",
          files: [
            %{
              path:
                "/downloads/completed/Test.Movie.2024.1080p.WEB-DL/Test.Movie.2024.1080p.WEB-DL.mkv",
              size: 2048
            }
          ]
        )

      media_item = media_item_fixture(%{type: "movie", title: "Test Movie", year: 2024})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "MockSABnzbd",
          download_client_id: nzo_id,
          title: "Test.Movie.2024.1080p.WEB-DL"
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      updated = Downloads.get_download!(download.id)
      assert updated.completed_at != nil
      assert updated.save_path == save_path

      result =
        perform_job(MediaImport, %{
          "download_id" => download.id,
          "save_path" => save_path,
          "use_hardlinks" => false,
          "move_files" => true
        })

      assert {:ok, _} = result

      final = Downloads.get_download!(download.id)
      assert final.imported_at != nil
    end
  end

  describe "SABnzbd naming" do
    test "file upload preserves title in filename" do
      config = %{
        type: :sabnzbd,
        host: URI.parse(UsenetE2EHelpers.sabnzbd_url()).host,
        port: URI.parse(UsenetE2EHelpers.sabnzbd_url()).port,
        api_key: "test-api-key",
        use_ssl: false,
        url_base: nil,
        options: %{}
      }

      {:ok, nzo_id} =
        Mydia.Downloads.Client.Sabnzbd.add_torrent(
          config,
          {:file, "fake nzb content"},
          title: "My.Great.Show.S01E01.720p"
        )

      {:ok, %{status: 200, body: body}} =
        Req.get("#{UsenetE2EHelpers.sabnzbd_url()}/_test/uploads/#{nzo_id}")

      assert body["uploaded_filename"] == "My.Great.Show.S01E01.720p.nzb"
    end
  end
end
