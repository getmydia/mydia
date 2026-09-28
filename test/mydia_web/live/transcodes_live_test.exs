defmodule MydiaWeb.TranscodesLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Downloads

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  describe "mount and listing" do
    test "mounts /admin/transcodes with empty job list", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/transcodes")

      assert html =~ "Active Transcodes"
      assert has_element?(view, "#transcode-jobs")
      assert render(view) =~ "No active transcodes"
    end

    test "renders active transcode jobs including pending jobs with nil started_at", %{conn: conn} do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "Inception.2010.mkv",
          size: 2_000_000_000
        )

      # 1. Pending job with started_at: nil
      {:ok, pending_job} = Downloads.get_or_create_job(media_file.id, "1080p")
      assert is_nil(pending_job.started_at)

      # 2. Transcoding job with started_at set and progress
      {:ok, active_job} = Downloads.get_or_create_job(media_file.id, "720p")
      {:ok, active_job} = Downloads.update_job_progress(active_job, 0.45)
      refute is_nil(active_job.started_at)

      {:ok, view, _html} = live(conn, ~p"/admin/transcodes")

      # Both jobs rendered in table
      assert has_element?(view, "#transcode-jobs")
      assert render(view) =~ "Inception.2010.mkv"
      assert render(view) =~ "1080p"
      assert render(view) =~ "720p"
      assert render(view) =~ "45.0%"
      assert render(view) =~ "Pending"
      refute render(view) =~ "No active transcodes"
    end

    test "cancels a transcode job", %{conn: conn} do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "Interstellar.2014.mkv",
          size: 3_000_000_000
        )

      {:ok, job} = Downloads.get_or_create_job(media_file.id, "1080p")

      {:ok, view, _html} = live(conn, ~p"/admin/transcodes")
      assert has_element?(view, ~s|a[phx-click="cancel"][phx-value-id="#{job.id}"]|)

      view
      |> element(~s|a[phx-click="cancel"][phx-value-id="#{job.id}"]|)
      |> render_click()

      assert render(view) =~ "Job cancelled"
    end
  end
end
