defmodule MydiaWeb.Features.GuestTest do
  @moduledoc """
  Browser coverage for the guest request system.

  Scope is deliberately narrow. The full lifecycle is covered far faster by
  `MydiaWeb.GuestRequestFlowTest`; what only a real browser can prove is that
  the request and approve modals, and their phx-click wiring, actually work.

  Metadata is served by `Mydia.MetadataStubProvider`, so approval genuinely
  succeeds. An earlier version of this file let approval fail against the live
  relay and asserted on a `page_source` substring that `/admin/requests` always
  contains, so it passed regardless.
  """

  use MydiaWeb.FeatureCase, async: false

  import Mydia.MetadataStub

  alias Mydia.Media.MediaRequest
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  @moduletag :feature

  setup :setup_metadata_stub

  describe "Guest Navigation & Access Control" do
    @tag :feature
    test "guest can access dashboard after login", %{session: session} do
      login_as_guest(session)

      session
      |> wait_for_liveview()
      |> assert_path("/")
      |> assert_has_text("Dashboard")
    end

    @tag :feature
    test "guest cannot access admin pages", %{session: session} do
      login_as_guest(session)
      session |> wait_for_liveview()

      session
      |> visit("/admin/requests")
      |> wait_for_liveview()

      refute Wallaby.Browser.current_path(session) == "/admin/requests"
    end
  end

  describe "End-to-end request and approval in a real browser" do
    @tag :feature
    @tag timeout: 180_000
    test "guest requests a movie through the modal and an admin approves it",
         %{session: session} do
      guest = create_guest_user()
      admin = create_admin_user()

      # --- Guest submits through the modal ---
      login(session, guest.username, "password123")
      session |> wait_for_liveview()

      session
      |> visit("/request/movie?q=stub")
      |> wait_for_liveview()
      |> assert_has_text(MetadataStubProvider.movie_title())

      session
      |> js_click(~s(button[phx-click="open_request_modal"][phx-value-index="0"]))

      assert Wallaby.Browser.has_css?(session, "#request-modal-form")

      Wallaby.Browser.execute_script(session, """
        var form = document.getElementById('request-modal-form');
        if (form) { form.requestSubmit(); }
      """)

      request = wait_for_request(MetadataStubProvider.movie_tmdb_id())

      assert request.status == "pending"
      assert request.requester_id == guest.id

      # --- Admin approves through the modal ---
      login(session, admin.username, "password123")
      session |> wait_for_liveview()

      session
      |> visit("/admin/requests")
      |> wait_for_liveview()
      |> assert_has_text(MetadataStubProvider.movie_title())

      session
      |> js_click(~s(button[phx-click="open_approve_modal"][phx-value-id="#{request.id}"]))

      assert Wallaby.Browser.has_css?(session, "#approve-form")

      Wallaby.Browser.execute_script(session, """
        var form = document.getElementById('approve-form');
        if (form) { form.requestSubmit(); }
      """)

      # Assert database state. Never assert on a page_source substring here:
      # the filter tabs render phx-value-status="approved" unconditionally.
      approved = wait_for_status(request.id, "approved")

      assert approved.approved_by_id == admin.id
      refute is_nil(approved.media_item_id)
    end
  end

  # Wallaby has no built-in wait on database state, and the LiveView write
  # happens after the browser returns from requestSubmit.
  defp wait_for_request(tmdb_id, attempts \\ 40) do
    case Repo.get_by(MediaRequest, tmdb_id: tmdb_id) do
      nil when attempts > 0 ->
        :timer.sleep(250)
        wait_for_request(tmdb_id, attempts - 1)

      nil ->
        raise "no media request with tmdb_id #{tmdb_id} was created after waiting"

      request ->
        request
    end
  end

  defp wait_for_status(id, status, attempts \\ 40) do
    request = Repo.get!(MediaRequest, id)

    cond do
      request.status == status ->
        request

      attempts > 0 ->
        :timer.sleep(250)
        wait_for_status(id, status, attempts - 1)

      true ->
        raise "request #{id} never reached status #{status}, last saw #{request.status}"
    end
  end
end
