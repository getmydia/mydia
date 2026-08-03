defmodule MydiaWeb.MediaLive.SegmentStatusTest do
  # Connected LiveView tests must not be async: the Postgres non-shared sandbox
  # otherwise hides test rows from the mount process. The fingerprint
  # implementation is also swapped through Application env, which is global.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Library.MediaFile
  alias Mydia.Library.MediaSegment
  alias Mydia.Repo

  defmodule AvailableStub do
    @moduledoc false

    @behaviour Mydia.Library.SegmentDetection.Fingerprint

    @impl true
    def available?, do: true

    @impl true
    def fingerprint(_path, _start_s, _length_s), do: {:error, :not_used}
  end

  defmodule UnavailableStub do
    @moduledoc false

    @behaviour Mydia.Library.SegmentDetection.Fingerprint

    @impl true
    def available?, do: false

    @impl true
    def fingerprint(_path, _start_s, _length_s), do: {:error, :fpcalc_not_found}
  end

  setup %{conn: conn} do
    # The row is a capability-gated view of real detection, so the host's
    # chromaprint install must not decide what the test sees.
    Application.put_env(:mydia, :fingerprint_impl, AvailableStub)
    on_exit(fn -> Application.delete_env(:mydia, :fingerprint_impl) end)

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp show_with_season do
    media_item = media_item_fixture(%{type: "tv_show"})

    files =
      for n <- 1..2 do
        episode =
          episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: n})

        media_file_fixture(%{episode_id: episode.id})
      end

    {media_item, files}
  end

  defp detect(file, opts \\ []) do
    Repo.insert!(
      MediaSegment.changeset(%MediaSegment{}, %{
        media_file_id: file.id,
        type: Keyword.get(opts, :type, "intro"),
        start_ms: Keyword.get(opts, :start_ms, 35_000),
        end_ms: Keyword.get(opts, :end_ms, 125_000),
        source: Keyword.get(opts, :source, "fingerprint"),
        confidence: 0.8
      })
    )

    file |> Ecto.Changeset.change(%{segment_analysis_state: "detected"}) |> Repo.update!()
  end

  test "shows a detected badge, both offsets and the provenance chip", %{conn: conn} do
    {media_item, files} = show_with_season()

    for file <- files do
      detect(file)
      detect(file, type: "credits", start_ms: 1_320_000, end_ms: 1_400_000)
    end

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    assert has_element?(view, "#segment-status-season-1")
    assert has_element?(view, "#segment-state-season-1", "Detected")
    assert has_element?(view, "#segment-intro-season-1", "0:35")
    assert has_element?(view, "#segment-intro-season-1", "2:05")
    assert has_element?(view, "#segment-credits-season-1", "22:00")
    assert has_element?(view, "#segment-status-season-1", "fingerprint")
  end

  test "shows a partial badge and says how many files carry the segment", %{conn: conn} do
    {media_item, [first | _rest]} = show_with_season()

    detect(first)

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    assert has_element?(view, "#segment-state-season-1", "Partial")
    # The offset belongs to one episode of two, and the row has to say so
    # rather than implying the whole season shares it.
    assert has_element?(view, "#segment-intro-season-1", "1 of 2")
    assert has_element?(view, "#segment-credits-season-1", "-")
  end

  test "shows every provenance a mixed season used", %{conn: conn} do
    {media_item, [first, second]} = show_with_season()

    detect(first, source: "fingerprint")
    detect(second, source: "chapters")

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    assert has_element?(view, "#segment-status-season-1", "chapters")
    assert has_element?(view, "#segment-status-season-1", "fingerprint")
  end

  test "shows a pending badge before detection has run", %{conn: conn} do
    {media_item, _files} = show_with_season()

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    assert has_element?(view, "#segment-state-season-1", "Pending")
    assert has_element?(view, "#segment-intro-season-1", "-")
    assert has_element?(view, "#segment-credits-season-1", "-")
  end

  test "re-analyze clears segments and returns files to pending", %{conn: conn} do
    {media_item, files} = show_with_season()

    for file <- files do
      detect(file)

      file
      |> Ecto.Changeset.change(%{
        segment_analysis_attempts: 2,
        last_segment_analysis_error: "boom"
      })
      |> Repo.update!()
    end

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    view |> element("#segment-reanalyze-season-1") |> render_click()

    for file <- files do
      reloaded = Repo.preload(Repo.get!(MediaFile, file.id), :segments)

      assert reloaded.segment_analysis_state == "pending"
      assert reloaded.segment_analysis_attempts == 0
      assert reloaded.last_segment_analysis_error == nil
      assert reloaded.segments == []
    end

    assert has_element?(view, "#segment-state-season-1", "Pending")
  end

  test "shows one note and no rows when chromaprint is missing", %{conn: conn} do
    Application.put_env(:mydia, :fingerprint_impl, UnavailableStub)

    {media_item, [first | _rest]} = show_with_season()

    detect(first)

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    assert has_element?(view, "#segment-detection-unavailable")
    refute has_element?(view, "#segment-status-season-1")
    refute has_element?(view, "#segment-reanalyze-season-1")
  end
end
