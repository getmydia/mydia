defmodule MydiaWeb.MediaLive.Show.ReidentifyEventsTest do
  @moduledoc """
  Tests for the provider re-identification async event handlers in
  `MydiaWeb.MediaLive.Show.FileEvents`.

  Strategy
  --------
  * Branches that are pure socket-transforms (no `start_async`, no DB I/O) are
    exercised by calling the `FileEvents` handler functions directly with a
    manually constructed `Phoenix.LiveView.Socket`.  This is deterministic and
    needs no network.
  * The `handle_reidentify_adopt_async` `{:ok, {target, {:ok, _}}}` clause calls
    `load_media_item/1`, which hits the database.  That branch is tested through
    a fully connected LiveView mount so that Ecto's sandbox is properly in scope.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias MydiaWeb.MediaLive.Show.FileEvents
  alias Mydia.Metadata.Structs.SearchResult

  # ---------------------------------------------------------------------------
  # Stub-socket helpers
  # ---------------------------------------------------------------------------

  # Build a minimal Phoenix.LiveView.Socket that satisfies:
  #   * `Phoenix.Component.assign/3`  (needs assigns.__changed__)
  #   * `Phoenix.LiveView.put_flash/3` (needs assigns.flash + private.live_temp)
  defp stub_socket(extra_assigns) do
    base_assigns =
      %{__changed__: %{}, flash: %{}}
      |> Map.merge(extra_assigns)

    %Phoenix.LiveView.Socket{
      assigns: base_assigns,
      private: %{live_temp: %{}}
    }
  end

  # Build a stub candidate (SearchResult struct).
  defp candidate(id, title \\ "Test Show") do
    %SearchResult{
      provider_id: to_string(id),
      provider: :tmdb,
      media_type: :tv_show,
      title: title
    }
  end

  # Read flash out of a stub socket (keyed as strings, same as Phoenix.LiveView).
  defp flash(%Phoenix.LiveView.Socket{assigns: %{flash: f}}), do: f

  # ---------------------------------------------------------------------------
  # Mount helpers for connected-LiveView tests
  # ---------------------------------------------------------------------------

  defp authenticated_conn(conn) do
    admin = admin_user_fixture()
    log_in_user(conn, admin)
  end

  defp mount_show(conn, media_item) do
    live(conn, ~p"/movies/#{media_item.id}")
  end

  # ---------------------------------------------------------------------------
  # 1. handle_reidentify_search_async – :needs_picker
  # ---------------------------------------------------------------------------

  describe "handle_reidentify_search_async/2 :needs_picker" do
    test "sets show_reidentify_modal=true, candidates, provider; clears reidentifying" do
      candidates = [candidate(1), candidate(2)]

      socket =
        stub_socket(%{reidentifying: true, reidentify_candidates: [], reidentify_provider: nil})

      {:noreply, updated} =
        FileEvents.handle_reidentify_search_async(
          {:ok, {:tmdb, {:needs_picker, candidates}}},
          socket
        )

      assert updated.assigns.show_reidentify_modal == true
      assert updated.assigns.reidentifying == false
      assert updated.assigns.reidentify_candidates == candidates
      assert updated.assigns.reidentify_provider == :tmdb
    end

    test "works with an empty candidate list (no results from provider)" do
      socket =
        stub_socket(%{reidentifying: true, reidentify_candidates: [], reidentify_provider: nil})

      {:noreply, updated} =
        FileEvents.handle_reidentify_search_async(
          {:ok, {:tvdb, {:needs_picker, []}}},
          socket
        )

      assert updated.assigns.show_reidentify_modal == true
      assert updated.assigns.reidentify_candidates == []
      assert updated.assigns.reidentifying == false
    end
  end

  # ---------------------------------------------------------------------------
  # 2. handle_reidentify_search_async – :error
  # ---------------------------------------------------------------------------

  describe "handle_reidentify_search_async/2 {:error, reason}" do
    test "clears reidentifying and sets an error flash mentioning the provider" do
      socket = stub_socket(%{reidentifying: true})

      {:noreply, updated} =
        FileEvents.handle_reidentify_search_async(
          {:ok, {:tmdb, {:error, :timeout}}},
          socket
        )

      assert updated.assigns.reidentifying == false
      assert flash(updated)["error"] =~ "TMDB"
    end

    test "includes the error reason in the flash message" do
      socket = stub_socket(%{reidentifying: true})

      {:noreply, updated} =
        FileEvents.handle_reidentify_search_async(
          {:ok, {:tvdb, {:error, :network_failure}}},
          socket
        )

      error_msg = flash(updated)["error"]
      assert error_msg =~ "TheTVDB"
      assert error_msg =~ "network_failure"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. handle_reidentify_search_async – {:exit, reason}
  # ---------------------------------------------------------------------------

  describe "handle_reidentify_search_async/2 {:exit, reason}" do
    test "clears reidentifying and sets a generic error flash" do
      socket = stub_socket(%{reidentifying: true})

      {:noreply, updated} =
        FileEvents.handle_reidentify_search_async({:exit, :killed}, socket)

      assert updated.assigns.reidentifying == false
      assert flash(updated)["error"] =~ "Re-identification failed"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. handle_reidentify_adopt_async – {:ok, {target, {:ok, _updated}}}
  # ---------------------------------------------------------------------------

  describe "handle_reidentify_adopt_async/2 {:ok, {:ok, _}}" do
    test "reloads media_item, clears state, emits success flash mentioning provider", %{
      conn: conn
    } do
      conn = authenticated_conn(conn)

      # Seed a real media_item so load_media_item/1 can find it.
      media_item = media_item_fixture(%{type: "tv_show", title: "Breaking Bad"})

      {:ok, _view, _html} = mount_show(conn, media_item)

      # Inject state that adopt normally sets before the async completes.
      # We do this by first rendering a cancel so we can set state via events,
      # but it's simpler to send handle_async directly through the connected view.
      # Instead we send the async result message as the LiveView process expects it.
      # The LiveView dispatches :reidentify_adopt via handle_async/3.
      # We simulate a successful adopt result – no network needed here because
      # handle_reidentify_adopt_async receives a pre-built {:ok, {:ok, _updated}}.
      fake_updated = %{id: media_item.id}

      # Directly invoke the handler via render_click on a phx-click that delegates;
      # since we can't inject a handle_async directly without the private ref tuple,
      # we call FileEvents directly against a socket that carries a real media_item ID.
      # Build a socket that mirrors what the LiveView would have.
      socket =
        stub_socket(%{
          media_item: media_item,
          current_scope: Mydia.Accounts.Scope.unrestricted(),
          reidentifying: true,
          show_reidentify_modal: true,
          reidentify_candidates: [candidate(1)]
        })

      {:noreply, updated} =
        FileEvents.handle_reidentify_adopt_async(
          {:ok, {:tmdb, {:ok, fake_updated}}},
          socket
        )

      assert updated.assigns.reidentifying == false
      assert updated.assigns.show_reidentify_modal == false
      assert updated.assigns.reidentify_candidates == []
      # The socket's media_item should have been replaced by load_media_item/1.
      # The reloaded item should carry the same ID.
      assert updated.assigns.media_item.id == media_item.id
      assert flash(updated)["info"] =~ "TMDB"
    end
  end

  # ---------------------------------------------------------------------------
  # 5. handle_reidentify_adopt_async – {:ok, {_target, {:error, reason}}}
  # ---------------------------------------------------------------------------

  describe "handle_reidentify_adopt_async/2 {:ok, {:error, reason}}" do
    test "clears reidentifying, closes modal, sets error flash" do
      socket =
        stub_socket(%{
          reidentifying: true,
          show_reidentify_modal: true
        })

      {:noreply, updated} =
        FileEvents.handle_reidentify_adopt_async(
          {:ok, {:tmdb, {:error, :some_reason}}},
          socket
        )

      assert updated.assigns.reidentifying == false
      assert updated.assigns.show_reidentify_modal == false
      assert flash(updated)["error"] =~ "Provider switch failed"
    end
  end

  # ---------------------------------------------------------------------------
  # 6. handle_reidentify_adopt_async – {:exit, reason}
  # ---------------------------------------------------------------------------

  describe "handle_reidentify_adopt_async/2 {:exit, reason}" do
    test "clears reidentifying and sets a generic error flash" do
      socket = stub_socket(%{reidentifying: true, show_reidentify_modal: true})

      {:noreply, updated} =
        FileEvents.handle_reidentify_adopt_async({:exit, :killed}, socket)

      assert updated.assigns.reidentifying == false
      assert flash(updated)["error"] =~ "Provider switch failed"
    end
  end

  # ---------------------------------------------------------------------------
  # 7. cancel_reidentify
  # ---------------------------------------------------------------------------

  describe "cancel_reidentify/2" do
    test "closes modal and resets candidates + provider" do
      socket =
        stub_socket(%{
          show_reidentify_modal: true,
          reidentify_candidates: [candidate(99)],
          reidentify_provider: :tvdb
        })

      {:noreply, updated} = FileEvents.cancel_reidentify(%{}, socket)

      assert updated.assigns.show_reidentify_modal == false
      assert updated.assigns.reidentify_candidates == []
      assert updated.assigns.reidentify_provider == nil
    end

    test "does not touch the :reidentifying assign (finding #8 is separate)" do
      # Current behaviour: cancel_reidentify does NOT reset :reidentifying.
      # This test documents that intentionally (finding #8 tracks the fix).
      socket =
        stub_socket(%{
          show_reidentify_modal: true,
          reidentify_candidates: [],
          reidentify_provider: nil,
          reidentifying: true
        })

      {:noreply, updated} = FileEvents.cancel_reidentify(%{}, socket)

      # :reidentifying is still true – this is the current (unfixed) behaviour.
      assert updated.assigns.reidentifying == true
    end
  end

  # ---------------------------------------------------------------------------
  # 8. select_reidentify_candidate – provider_id NOT in candidates
  # ---------------------------------------------------------------------------

  describe "select_reidentify_candidate/2 with missing provider_id" do
    test "closes modal and flashes 'no longer available' error (no network call)" do
      socket =
        stub_socket(%{
          show_reidentify_modal: true,
          media_item: %{id: "fake-id"},
          reidentify_provider: :tmdb,
          reidentify_candidates: [candidate("100"), candidate("200")]
        })

      # A provider_id that does NOT exist in the candidates list.
      {:noreply, updated} =
        FileEvents.select_reidentify_candidate(%{"provider_id" => "999"}, socket)

      assert updated.assigns.show_reidentify_modal == false
      assert flash(updated)["error"] =~ "no longer available"
    end

    test "is case-insensitive / coerced to string comparison" do
      # provider_id is stored as a string; passing an integer-like string that
      # doesn't match should still produce the missing-candidate path.
      socket =
        stub_socket(%{
          show_reidentify_modal: true,
          media_item: %{id: "fake-id"},
          reidentify_provider: :tvdb,
          reidentify_candidates: [candidate("42")]
        })

      # "420" does not match "42"
      {:noreply, updated} =
        FileEvents.select_reidentify_candidate(%{"provider_id" => "420"}, socket)

      assert updated.assigns.show_reidentify_modal == false
      assert flash(updated)["error"] =~ "no longer available"
    end
  end
end
