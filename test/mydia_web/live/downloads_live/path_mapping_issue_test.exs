defmodule MydiaWeb.DownloadsLive.PathMappingIssueTest do
  # async: false — connected LiveView mount runs in a separate process; shared
  # sandbox is required so it sees the rows inserted here (see index_test.exs).
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Settings

  setup do
    # The app skips Oban in test (engine: false), so Oban.insert can't be
    # resolved from the LiveView process. Start an isolated, manual-mode Oban
    # for these tests so the fan-out re-enqueue works and assert_enqueued can
    # observe it. Engine is derived from the repo adapter (SQLite or Postgres).
    start_supervised!(
      {Oban, repo: Mydia.Repo, engine: Mydia.AdapterHelpers.oban_engine(), testing: :manual}
    )

    :ok
  end

  defp mismatch_download(reported_path, attrs \\ %{}) do
    media_item = media_item_fixture()

    download_fixture(
      Map.merge(
        %{
          media_item_id: media_item.id,
          status: "completed",
          import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          import_failure_reason: "path_mapping_mismatch",
          import_reported_path: reported_path,
          import_last_error: "Mydia can't access the download path: #{reported_path}."
        },
        attrs
      )
    )
  end

  describe "apply mapping and retry" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_user_fixture())}
    end

    test "renders an actionable mismatch entry in the issues tab", %{conn: conn} do
      download = mismatch_download("/downloads/complete/Severance.S02E10")

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_patch(view, ~p"/downloads?tab=issues")

      # The row names the failure and offers a fix; the longer explanation
      # lives in the detail drawer.
      assert has_element?(
               view,
               "#issues-#{download.id}",
               "Mydia can't access the download path"
             )

      assert has_element?(view, "#issues-#{download.id} #retry-import-#{download.id}") or
               has_element?(view, "#issues-#{download.id} #apply-mapping-#{download.id}")
    end

    test "applying a mapping persists it and re-runs every affected mismatch", %{conn: conn} do
      a =
        mismatch_download("/downloads/complete/A", %{
          path_mapping_remote_prefix: "/downloads/complete",
          path_mapping_local_prefix: "/data/torrents/complete",
          path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      b = mismatch_download("/downloads/complete/B")
      # a non-failed download under the same prefix must NOT be touched
      untouched =
        mismatch_download("/downloads/complete/C", %{
          import_failed_at: nil,
          import_failure_reason: nil
        })

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_patch(view, ~p"/downloads?tab=issues")

      render_click(view, "apply_mapping_and_retry", %{
        "remote_prefix" => "/downloads/complete",
        "local_prefix" => "/data/torrents/complete"
      })

      assert [mapping] = Settings.list_path_mapping_configs()
      assert mapping.local_prefix == "/data/torrents/complete"

      assert is_nil(Downloads.get_download!(a.id).import_failed_at)
      assert is_nil(Downloads.get_download!(a.id).path_mapping_remote_prefix)
      assert is_nil(Downloads.get_download!(b.id).import_failed_at)
      # untouched was never failed, so its (nil) state is unchanged and no job runs
      refute is_nil(Downloads.get_download!(untouched.id))

      assert_enqueued(worker: Mydia.Jobs.MediaImport, args: %{"download_id" => a.id})
      assert_enqueued(worker: Mydia.Jobs.MediaImport, args: %{"download_id" => b.id})
      refute_enqueued(worker: Mydia.Jobs.MediaImport, args: %{"download_id" => untouched.id})
    end

    test "a duplicate prefix surfaces an error and adds no second mapping", %{conn: conn} do
      mismatch_download("/downloads/complete/A")

      {:ok, _} =
        Settings.create_path_mapping_config(%{
          remote_prefix: "/downloads/complete",
          local_prefix: "/data/existing"
        })

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_patch(view, ~p"/downloads?tab=issues")

      html =
        render_click(view, "apply_mapping_and_retry", %{
          "remote_prefix" => "/downloads/complete",
          "local_prefix" => "/data/torrents/complete"
        })

      assert html =~ "already exists"
      assert length(Settings.list_path_mapping_configs()) == 1
    end
  end

  describe "stored suggestion" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_user_fixture())}
    end

    test "the Issues tab offers the stored mapping with its affected count", %{conn: conn} do
      stored = %{
        path_mapping_remote_prefix: "/downloads/complete",
        path_mapping_local_prefix: "/data/torrents/complete",
        path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      download = mismatch_download("/downloads/complete/Fictional.Salt.Meridian.S01E01", stored)
      mismatch_download("/downloads/complete/Fictional.Salt.Meridian.S01E02", stored)

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_patch(view, ~p"/downloads?tab=issues")

      assert has_element?(
               view,
               "#apply-mapping-#{download.id}[phx-value-local_prefix='/data/torrents/complete']"
             )
    end

    test "a mismatch with no stored suggestion offers a plain retry", %{conn: conn} do
      download = mismatch_download("/downloads/complete/Fictional.Salt.Meridian.S01E03")

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_patch(view, ~p"/downloads?tab=issues")

      assert has_element?(view, "#retry-import-#{download.id}")
      refute has_element?(view, "#apply-mapping-#{download.id}")
    end

    test "the drawer shows the stored mapping", %{conn: conn} do
      download =
        mismatch_download("/downloads/complete/Fictional.Salt.Meridian.S01E04", %{
          path_mapping_remote_prefix: "/downloads/complete",
          path_mapping_local_prefix: "/data/torrents/complete",
          path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues&download=#{download.id}")

      assert has_element?(view, "#drawer-path-mapping", "/data/torrents/complete")
    end
  end

  describe "authorization" do
    test "a non-admin user cannot apply a mapping", %{conn: conn} do
      mismatch_download("/downloads/complete/A")
      conn = log_in_user(conn, user_fixture(%{role: "user"}))

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_patch(view, ~p"/downloads?tab=issues")

      html =
        render_click(view, "apply_mapping_and_retry", %{
          "remote_prefix" => "/downloads/complete",
          "local_prefix" => "/data/torrents/complete"
        })

      assert html =~ "Admin access required"
      assert Settings.list_path_mapping_configs() == []
    end
  end
end
