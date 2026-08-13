defmodule MydiaWeb.GuestRequestFlowTest do
  @moduledoc """
  End-to-end coverage of the guest request lifecycle at the LiveView layer.

  These tests exist because the browser suite asserted on `page_source`
  substrings that `/admin/requests` always contains, so approval could fail in
  CI while the test stayed green. Assert database state for anything that is a
  state change.
  """

  # async: false: setup_metadata_stub mutates the global Provider.Registry, and
  # connected LiveView mounts run in a separate process from the test, which the
  # non-shared Postgres sandbox hides rows from.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataStub

  alias Mydia.Media
  alias Mydia.Media.MediaRequest
  alias Mydia.MediaRequests
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  setup do
    guest = create_test_user(%{role: "guest"})
    admin = create_admin_user()

    %{guest: guest, admin: admin}
  end

  defp guest_conn(conn, guest), do: log_in_user(conn, guest)
  defp admin_conn(conn, admin), do: log_in_user(conn, admin)

  describe "movie request lifecycle" do
    test "guest submits a movie request and an admin approves it into the library",
         %{conn: conn, guest: guest, admin: admin} do
      # --- Guest submits ---
      {:ok, view, _html} = live(guest_conn(conn, guest), ~p"/request/movie?q=stub")

      assert render(view) =~ MetadataStubProvider.movie_title()

      view
      |> element(~s(button[phx-click="open_request_modal"][phx-value-index="0"]))
      |> render_click()

      view
      |> form("#request-modal-form", request: %{requester_notes: "Please add this one"})
      |> render_submit()

      request = Repo.get_by!(MediaRequest, tmdb_id: MetadataStubProvider.movie_tmdb_id())

      assert request.status == "pending"
      assert request.media_type == "movie"
      assert request.title == MetadataStubProvider.movie_title()
      assert request.requester_id == guest.id
      assert request.requester_notes == "Please add this one"
      assert is_nil(request.media_item_id)

      # --- Guest sees it pending ---
      {:ok, my_requests, _html} = live(guest_conn(conn, guest), ~p"/requests")
      assert render(my_requests) =~ MetadataStubProvider.movie_title()

      # --- Admin approves ---
      {:ok, admin_view, _html} = live(admin_conn(conn, admin), ~p"/admin/requests")

      assert render(admin_view) =~ MetadataStubProvider.movie_title()

      admin_view
      |> element(~s(button[phx-click="open_approve_modal"][phx-value-id="#{request.id}"]))
      |> render_click()

      admin_view
      |> form("#approve-form", approve: %{admin_notes: "Approved by test"})
      |> render_submit()

      # --- Assert real state, not rendered substrings ---
      approved = Repo.get!(MediaRequest, request.id)

      assert approved.status == "approved"
      assert approved.approved_by_id == admin.id
      refute is_nil(approved.approved_at)

      refute is_nil(approved.media_item_id),
             "approval must link the created media item; a nil id means the metadata fetch failed"

      media_item = Media.get_media_item!(approved.media_item_id)

      assert media_item.type == "movie"
      assert media_item.title == MetadataStubProvider.movie_title()
      assert media_item.tmdb_id == MetadataStubProvider.movie_tmdb_id()
    end
  end

  describe "tv request lifecycle" do
    test "guest submits a series request stored by tvdb id and approval creates the show",
         %{conn: conn, guest: guest, admin: admin} do
      {:ok, view, _html} = live(guest_conn(conn, guest), ~p"/request/series?q=stub")

      assert render(view) =~ MetadataStubProvider.series_title()

      view
      |> element(~s(button[phx-click="open_request_modal"][phx-value-index="0"]))
      |> render_click()

      view
      |> form("#request-modal-form", request: %{requester_notes: "Series please"})
      |> render_submit()

      request = Repo.get_by!(MediaRequest, tvdb_id: MetadataStubProvider.series_tvdb_id())

      assert request.status == "pending"
      assert request.media_type == "tv_show"
      assert request.requester_id == guest.id

      assert is_nil(request.tmdb_id),
             "a TVDB-sourced result must not be stored as a TMDB id, or approval routes to the wrong provider"

      {:ok, admin_view, _html} = live(admin_conn(conn, admin), ~p"/admin/requests")

      admin_view
      |> element(~s(button[phx-click="open_approve_modal"][phx-value-id="#{request.id}"]))
      |> render_click()

      admin_view
      |> form("#approve-form", approve: %{admin_notes: ""})
      |> render_submit()

      approved = Repo.get!(MediaRequest, request.id)

      assert approved.status == "approved"
      refute is_nil(approved.media_item_id)

      media_item = Media.get_media_item!(approved.media_item_id)

      assert media_item.type == "tv_show"
      assert media_item.title == MetadataStubProvider.series_title()
      assert media_item.tvdb_id == MetadataStubProvider.series_tvdb_id()
    end
  end

  describe "rejection" do
    test "admin rejects with a reason and the guest sees it", %{
      conn: conn,
      guest: guest,
      admin: admin
    } do
      {:ok, request} =
        MediaRequests.create_request(%{
          media_type: "movie",
          title: MetadataStubProvider.movie_title(),
          tmdb_id: MetadataStubProvider.movie_tmdb_id(),
          requester_id: guest.id
        })

      {:ok, admin_view, _html} = live(admin_conn(conn, admin), ~p"/admin/requests")

      admin_view
      |> element(~s(button[phx-click="open_reject_modal"][phx-value-id="#{request.id}"]))
      |> render_click()

      admin_view
      |> form("#reject-form", reject: %{rejection_reason: "Not suitable for this library"})
      |> render_submit()

      rejected = Repo.get!(MediaRequest, request.id)

      assert rejected.status == "rejected"
      assert rejected.rejection_reason == "Not suitable for this library"
      assert rejected.approved_by_id == admin.id
      assert is_nil(rejected.media_item_id)

      {:ok, my_requests, _html} = live(guest_conn(conn, guest), ~p"/requests")
      assert render(my_requests) =~ "Not suitable for this library"
    end
  end

  describe "duplicate detection" do
    test "a second pending request for the same media is refused", %{guest: guest} do
      attrs = %{
        media_type: "movie",
        title: MetadataStubProvider.movie_title(),
        tmdb_id: MetadataStubProvider.movie_tmdb_id(),
        requester_id: guest.id
      }

      {:ok, _first} = MediaRequests.create_request(attrs)

      assert {:error, :duplicate_request} = MediaRequests.create_request(attrs)
      assert Repo.aggregate(MediaRequest, :count) == 1
    end

    test "requesting media already in the library is refused", %{guest: guest, admin: admin} do
      # Approve one request so the media item exists in the library.
      {:ok, request} =
        MediaRequests.create_request(%{
          media_type: "movie",
          title: MetadataStubProvider.movie_title(),
          tmdb_id: MetadataStubProvider.movie_tmdb_id(),
          requester_id: guest.id
        })

      {:ok, _} =
        MediaRequests.approve_request(request, %{approved_by_id: admin.id})

      assert {:error, :duplicate_media} =
               MediaRequests.create_request(%{
                 media_type: "movie",
                 title: MetadataStubProvider.movie_title(),
                 tmdb_id: MetadataStubProvider.movie_tmdb_id(),
                 requester_id: guest.id
               })
    end
  end

  describe "metadata failure" do
    test "an unreachable provider leaves the request pending", %{
      conn: conn,
      guest: guest,
      admin: admin
    } do
      {:ok, request} =
        MediaRequests.create_request(%{
          media_type: "movie",
          title: "Unresolvable Movie",
          tmdb_id: MetadataStubProvider.missing_id(),
          requester_id: guest.id
        })

      {:ok, admin_view, _html} = live(admin_conn(conn, admin), ~p"/admin/requests")

      admin_view
      |> element(~s(button[phx-click="open_approve_modal"][phx-value-id="#{request.id}"]))
      |> render_click()

      html =
        admin_view
        |> form("#approve-form", approve: %{admin_notes: ""})
        |> render_submit()

      assert html =~ "Could not reach the metadata service"

      untouched = Repo.get!(MediaRequest, request.id)

      assert untouched.status == "pending"
      assert is_nil(untouched.media_item_id)
    end
  end

  describe "guardrails" do
    test "a guest cannot reach the admin requests page", %{conn: conn, guest: guest} do
      # UserAuth.on_mount({:ensure_role, :admin}) halts with redirect(to: "/")
      # (lib/mydia_web/live/user_auth.ex:70), so live/2 returns this tuple.
      assert {:error, {:redirect, %{to: "/"}}} =
               live(guest_conn(conn, guest), ~p"/admin/requests")
    end
  end
end
