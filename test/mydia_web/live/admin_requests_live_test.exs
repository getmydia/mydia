defmodule MydiaWeb.AdminRequestsLiveTest do
  @moduledoc """
  Covers the approve dialog's configuration controls specifically.

  The end-to-end request lifecycle lives in `guest_request_flow_test.exs`.
  This file is only about what the dialog offers and what the submitted
  values do.
  """

  # async: false for the same reason as guest_request_flow_test:
  # setup_metadata_stub mutates the global Provider.Registry.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.MediaRequests
  alias Mydia.MetadataStubProvider

  setup :setup_metadata_stub

  setup %{conn: conn} do
    guest = create_test_user(%{role: "guest"})
    admin = create_admin_user()

    {:ok, request} =
      MediaRequests.create_request(%{
        media_type: "movie",
        title: MetadataStubProvider.movie_title(),
        tmdb_id: MetadataStubProvider.movie_tmdb_id(),
        requester_id: guest.id
      })

    %{conn: log_in_user(conn, admin), admin: admin, guest: guest, request: request}
  end

  defp open_approve(view, request) do
    view
    |> element(~s(button[phx-click="open_approve_modal"][phx-value-id="#{request.id}"]))
    |> render_click()
  end

  describe "approve modal configuration fields" do
    test "renders the config controls", %{conn: conn, request: request} do
      library_path_fixture(%{type: "movies"})
      profile = quality_profile_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin/requests")
      html = open_approve(view, request)

      assert html =~ "config[library_path_id]"
      assert html =~ "config[quality_profile_id]"
      assert html =~ "config[monitored]"
      assert html =~ "config[search_on_add]"
      assert html =~ profile.name
    end

    test "omits season monitoring for a movie request", %{conn: conn, request: request} do
      library_path_fixture(%{type: "movies"})

      {:ok, view, _html} = live(conn, ~p"/admin/requests")

      refute open_approve(view, request) =~ "config[season_monitoring]"
    end

    test "blocks approval when no library path exists", %{conn: conn, request: request} do
      {:ok, view, _html} = live(conn, ~p"/admin/requests")
      html = open_approve(view, request)

      assert html =~ "No library paths configured"
      assert has_element?(view, "#approve-form button[type=submit][disabled]")
    end
  end
end
