defmodule MydiaWeb.GuestRequestFlowTest do
  @moduledoc """
  End-to-end coverage of the guest request lifecycle at the LiveView layer.

  These tests exist because the browser suite asserted on `page_source`
  substrings that `/admin/requests` always contains, so approval could fail in
  CI while the test stayed green. Assert database state for anything that is a
  state change.

  The guest submission step used to go through the now-deleted
  `RequestMediaLive.Index` (`/request/movie`), including a confirm-and-add-notes
  modal. Discover's one-click Request button has no such modal and no
  requester-notes field, so the submission steps below click the card's
  Request button directly and no longer exercise a notes field.
  """

  # async: false: setup_metadata_stub mutates the global Provider.Registry, and
  # connected LiveView mounts run in a separate process from the test, which the
  # non-shared Postgres sandbox hides rows from.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataStub
  import Mydia.MetadataCacheHelpers
  import Mydia.SettingsFixtures

  alias Mydia.Media
  alias Mydia.Media.MediaRequest
  alias Mydia.MediaRequests
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  setup do
    guest = create_test_user(%{role: "guest"})
    admin = create_admin_user()

    # Approving a request now requires a library path (AdminRequestsLive.Index
    # refuses the approval otherwise), so any test in this file that approves
    # needs one seeded. Do not delete this as unused-looking noise. Both types
    # are seeded because this file approves both a movie and a tv_show request
    # (see "movie request lifecycle" and "tv request lifecycle" below), and
    # AddDefaults.resolve/3 only offers a library whose type matches the
    # media being approved.
    library_path_fixture(%{type: "movies"})
    library_path_fixture(%{type: "series"})

    %{guest: guest, admin: admin}
  end

  defp guest_conn(conn, guest), do: log_in_user(conn, guest)
  defp admin_conn(conn, admin), do: log_in_user(conn, admin)

  # request_media's actual create happens in a handle_info the render_click
  # round trip does not wait on (it resolves the card from socket state
  # first), matching the wait_until_media_item/1 pattern in
  # discover_live/config_modal_test.exs.
  defp wait_until_request(clause, retries \\ 200)

  defp wait_until_request(clause, 0) do
    flunk("no MediaRequest matching #{inspect(clause)} was created in time")
  end

  defp wait_until_request(clause, retries) do
    case Repo.get_by(MediaRequest, clause) do
      nil ->
        Process.sleep(10)
        wait_until_request(clause, retries - 1)

      request ->
        request
    end
  end

  defp wait_until_media_item(clause, retries \\ 200)

  defp wait_until_media_item(clause, 0) do
    flunk("no MediaItem matching #{inspect(clause)} was created in time")
  end

  defp wait_until_media_item(clause, retries) do
    case Repo.get_by(Media.MediaItem, clause) do
      nil ->
        Process.sleep(10)
        wait_until_media_item(clause, retries - 1)

      media_item ->
        media_item
    end
  end

  describe "movie request lifecycle" do
    test "guest submits a movie request and an admin approves it into the library",
         %{conn: conn, guest: guest, admin: admin} do
      # --- Guest submits ---
      warm_genre_cache(:movie, [])
      {:ok, view, _html} = live(guest_conn(conn, guest), ~p"/discover?type=movie&q=stub")

      assert render(view) =~ MetadataStubProvider.movie_title()

      view
      |> element(
        ~s(button[phx-click="request_media"][phx-value-ref="tmdb:#{MetadataStubProvider.movie_tmdb_id()}"])
      )
      |> render_click()

      request = wait_until_request(tmdb_id: MetadataStubProvider.movie_tmdb_id())

      assert request.status == "pending"
      assert request.media_type == "movie"
      assert request.title == MetadataStubProvider.movie_title()
      assert request.requester_id == guest.id
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

    test "guest submits a movie request and an admin adding it via Discover auto-approves it",
         %{conn: conn, guest: guest, admin: admin} do
      # --- Guest submits request ---
      warm_genre_cache(:movie, [])
      {:ok, view, _html} = live(guest_conn(conn, guest), ~p"/discover?type=movie&q=stub")

      view
      |> element(
        ~s(button[phx-click="request_media"][phx-value-ref="tmdb:#{MetadataStubProvider.movie_tmdb_id()}"])
      )
      |> render_click()

      request = wait_until_request(tmdb_id: MetadataStubProvider.movie_tmdb_id())
      assert request.status == "pending"

      # --- Admin adds movie via Discover ---
      {:ok, admin_discover, _html} =
        live(admin_conn(conn, admin), ~p"/discover?type=movie&q=stub")

      admin_discover
      |> element(
        ~s(button[phx-click="add_to_library"][phx-value-ref="tmdb:#{MetadataStubProvider.movie_tmdb_id()}"])
      )
      |> render_click()

      # Wait for media item creation
      media_item =
        wait_until_media_item(
          type: "movie",
          tmdb_id: MetadataStubProvider.movie_tmdb_id()
        )

      # Request should now be auto-approved and linked
      approved = Repo.get!(MediaRequest, request.id)
      assert approved.status == "approved"
      assert approved.approved_by_id == admin.id
      assert approved.media_item_id == media_item.id
      refute is_nil(approved.approved_at)

      # --- Admin requests page shows it under approved, not pending ---
      {:ok, admin_requests, _html} = live(admin_conn(conn, admin), ~p"/admin/requests")
      refute render(admin_requests) =~ "request-#{request.id}"

      {:ok, approved_view, _html} =
        live(admin_conn(conn, admin), ~p"/admin/requests?status=approved")

      html = render(approved_view)
      assert html =~ "request-#{request.id}"
      assert html =~ admin.email
    end
  end

  describe "tv request lifecycle" do
    # `MediaRequestHelpers.handle_request_media/3` used to store the provider
    # id as tmdb_id unconditionally, even for a `provider: :tvdb` search
    # result. The deleted `RequestMediaLive.Index.build_request_attrs/3`
    # branched on the result's provider and stored tvdb_id for exactly this
    # case; that branch had been dropped somewhere between the two
    # implementations, so a TVDB-sourced TV request was misfiled under
    # tmdb_id (and MediaRequests' tmdb_id-only duplicate checks silently
    # skipped it). handle_request_media/3 now restores that branching, and
    # check_duplicate_media/1 and check_duplicate_request/1 also check
    # tvdb_id.
    test "guest submits a series request stored by tvdb id and approval creates the show",
         %{conn: conn, guest: guest, admin: admin} do
      warm_genre_cache(:tv_show, [])
      {:ok, view, _html} = live(guest_conn(conn, guest), ~p"/discover?type=tv_show&q=stub")

      assert render(view) =~ MetadataStubProvider.series_title()

      view
      |> element(
        ~s(button[phx-click="request_media"][phx-value-ref="tvdb:#{MetadataStubProvider.series_tvdb_id()}"])
      )
      |> render_click()

      request = wait_until_request(tvdb_id: MetadataStubProvider.series_tvdb_id())

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

      # The dialog stays open: it now holds configuration (library, quality
      # profile, monitoring) the admin picked, and a transient relay hiccup
      # must not discard those choices and force the admin to redo them.
      assert has_element?(admin_view, "#approve-form")

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
