defmodule MydiaWeb.SearchLive.GuestWriteTest do
  # Every write path on the page checks authorize_create_media/1. The UI
  # disables the buttons for a guest; these tests forge the events anyway.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataStub
  import MydiaWeb.AuthHelpers

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata
  alias Mydia.Repo

  setup :setup_metadata_stub

  setup %{conn: conn} do
    conn = log_in_user(conn, user_fixture(%{role: "guest"}))
    {:ok, view, _html} = live(conn, ~p"/search")

    {:ok, [match]} =
      Metadata.search(Metadata.default_relay_config(), "invented", media_type: :movie)

    %{view: view, match: match}
  end

  # The pending state normally arrives through write paths that are themselves
  # guarded, so a guest test has to plant it.
  defp assign_on_view(view, assigns) do
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      %{state | socket: %{socket | assigns: Map.merge(socket.assigns, assigns)}}
    end)
  end

  defp assert_nothing_created(view) do
    render_async(view, 2_000)
    assert Repo.aggregate(MediaItem, :count) == 0
  end

  test "select_manual_match creates nothing", %{view: view, match: match} do
    assign_on_view(view, %{metadata_matches: [match], metadata_media_type: :movie})

    html =
      render_click(view, "select_manual_match", %{
        "match_id" => to_string(match.provider_id),
        "media_type" => "movie"
      })

    assert html =~ "You do not have permission"
    assert_nothing_created(view)
  end

  test "select_metadata_match creates nothing", %{view: view, match: match} do
    assign_on_view(view, %{metadata_matches: [match], metadata_media_type: :movie})

    html =
      render_click(view, "select_metadata_match", %{"match_id" => to_string(match.provider_id)})

    assert html =~ "You do not have permission"
    assert_nothing_created(view)
  end

  test "manual_search_submit searches nothing", %{view: view} do
    html = render_submit(view, "manual_search_submit", %{"search_query" => "invented"})

    assert html =~ "You do not have permission"
    render_async(view, 2_000)
    assert :sys.get_state(view.pid).socket.assigns.metadata_matches == []
  end

  test "retry_add_to_library adds nothing", %{view: view} do
    assign_on_view(view, %{
      pending_release_title: "Invented.Feature.2021",
      pending_media_type: :movie
    })

    html = render_click(view, "retry_add_to_library", %{})

    assert html =~ "You do not have permission"
    assert_nothing_created(view)
  end
end
