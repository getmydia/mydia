defmodule MydiaWeb.Features.GuestTest do
  @moduledoc """
  Scope is deliberately narrow. The full lifecycle is covered far faster by
  `MydiaWeb.GuestRequestFlowTest`, and guest route access by
  `MydiaWeb.RouteAuthorizationTest`. What only a real browser can prove is
  that the approve modal and Discover's one-click Request button, and their
  phx-click wiring, actually work.

  Metadata is served by `Mydia.MetadataStubProvider`, so approval genuinely
  succeeds. An earlier version of this file let approval fail against the live
  relay and asserted on a `page_source` substring that `/admin/requests` always
  contains, so it passed regardless.
  """

  use MydiaWeb.FeatureCase, async: false

  import Mydia.MetadataStub
  import Mydia.MetadataCacheHelpers

  alias Mydia.Media.MediaRequest
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  @moduletag :feature

  setup :setup_metadata_stub

  # `Mydia.Metadata.genres/1` calls `Provider.Relay.fetch_genres/2` directly
  # and never consults `Provider.Registry`, so `setup_metadata_stub` cannot
  # intercept it. DiscoverLive fires `:load_genres` on connected mount, and
  # sending guests to Discover is what first put this test on that page, so
  # without a warm cache the run reaches the live relay and the network guard
  # fails the job even though every test passed. Warmed after the stub setup,
  # which clears the cache on its way in.
  setup do
    warm_genre_cache(:movie, [])
    :ok
  end

  describe "End-to-end request and approval in a real browser" do
    @tag :feature
    @tag timeout: 180_000
    test "guest requests a movie through Discover and an admin approves it",
         %{session: session} do
      guest = create_guest_user()
      admin = create_admin_user()

      # --- Guest submits through Discover's one-click Request button ---
      login(session, guest.username, "password123")
      session |> wait_for_liveview()

      session
      |> visit("/discover?type=movie&q=stub")
      |> wait_for_liveview()
      |> assert_has_text(MetadataStubProvider.movie_title())

      session
      |> click(
        Query.css(
          ~s(button[phx-click="request_media"][phx-value-ref="tmdb:#{MetadataStubProvider.movie_tmdb_id()}"])
        )
      )

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
      |> click(
        Query.css(~s(button[phx-click="open_approve_modal"][phx-value-id="#{request.id}"]))
      )

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
  defp wait_for_request(tmdb_id) do
    eventually(
      fn ->
        case Repo.get_by(MediaRequest, tmdb_id: tmdb_id) do
          nil -> :error
          request -> {:ok, request}
        end
      end,
      description: "a media request with tmdb_id #{tmdb_id}"
    )
  end

  defp wait_for_status(id, status) do
    eventually(
      fn ->
        request = Repo.get!(MediaRequest, id)
        if request.status == status, do: {:ok, request}, else: :error
      end,
      description: "request #{id} to reach status #{status}"
    )
  end
end
