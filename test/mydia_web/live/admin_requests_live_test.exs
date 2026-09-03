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

  describe "approving with a configuration" do
    test "the chosen library and profile land on the created item", %{
      conn: conn,
      request: request
    } do
      library = library_path_fixture(%{type: "movies"})
      profile = quality_profile_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin/requests")
      open_approve(view, request)

      view
      |> form("#approve-form", %{
        "approve" => %{"admin_notes" => ""},
        "config" => %{
          "library_path_id" => library.id,
          "quality_profile_id" => profile.id,
          "monitored" => "true",
          "search_on_add" => "false"
        }
      })
      |> render_submit()

      updated = MediaRequests.get_request!(request.id, preload: [:media_item])

      assert updated.status == "approved"
      assert updated.media_item.library_path_id == library.id
      assert updated.media_item.quality_profile_id == profile.id
    end

    test "an unavailable library flashes and closes without approving", %{
      conn: conn,
      request: request
    } do
      library_path_fixture(%{type: "movies"})

      {:ok, view, _html} = live(conn, ~p"/admin/requests")
      open_approve(view, request)

      # render_submit/3 (view + event name), not form/3: the scenario is a
      # library removed server-side after the dialog rendered, so the admin's
      # browser still holds a now-stale <option> the current DOM no longer
      # offers. form/3 validates the submitted value against the live
      # rendered <select> and would reject it before the event even reaches
      # the server, defeating the point of the test.
      html =
        render_submit(view, "submit_approve", %{
          "approve" => %{"admin_notes" => ""},
          "config" => %{"library_path_id" => Ecto.UUID.generate()}
        })

      assert html =~ "no longer available"
      assert MediaRequests.get_request!(request.id).status == "pending"
    end
  end

  describe "a failed approval keeps the dialog open" do
    test "a metadata failure preserves the admin's choices", %{
      conn: conn,
      guest: guest
    } do
      library = library_path_fixture(%{type: "movies"})
      profile = quality_profile_fixture()

      # missing_id/0 is the stub provider's "this does not resolve" id, the
      # same one guest_request_flow_test uses for its unreachable-provider case.
      {:ok, unresolvable} =
        MediaRequests.create_request(%{
          media_type: "movie",
          title: "Unresolvable Movie",
          tmdb_id: MetadataStubProvider.missing_id(),
          requester_id: guest.id
        })

      {:ok, view, _html} = live(conn, ~p"/admin/requests")
      open_approve(view, unresolvable)

      html =
        view
        |> form("#approve-form", %{
          "approve" => %{"admin_notes" => "keep me"},
          "config" => %{
            "library_path_id" => library.id,
            "quality_profile_id" => profile.id,
            "monitored" => "false",
            "search_on_add" => "false"
          }
        })
        |> render_submit()

      assert html =~ "Could not reach the metadata service"
      assert MediaRequests.get_request!(unresolvable.id).status == "pending"

      # The dialog is still open, still showing what was picked.
      assert has_element?(view, "#approve-form")
      assert has_element?(view, ~s(option[value="#{library.id}"][selected]))
      assert has_element?(view, ~s(option[value="#{profile.id}"][selected]))
    end
  end
end
