defmodule MydiaWeb.AddMediaLive.RemoteFilterWiringTest do
  @moduledoc """
  Proves `AddMediaLive.Index`'s `handle_info({:perform_search, ...}, socket)`
  actually pipes provider search results through
  `RemoteFilter.filter/2` before assigning `:search_results`, not just that
  `RemoteFilter.allow?/2` works in isolation.

  `/add/movie` and `/add/series` sit in the `:authenticated` `live_session`
  (`router.ex`) with no admin gate, so any restricted non-admin account can
  reach this search and, before this fix, would see out-of-bounds provider
  hits ready to quick-add straight into the library.

  Built with a hand-constructed socket and `handle_info/2` called directly,
  the same seam `discover_live/remote_filter_wiring_test.exs` uses, so this
  needs no connected mount.
  """

  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataStub

  alias Mydia.Accounts.Scope
  alias Mydia.Metadata
  alias Mydia.MetadataStubProvider
  alias MydiaWeb.AddMediaLive.Index

  setup :setup_metadata_stub

  defp stub_socket(assigns) do
    defaults = %{
      __changed__: %{},
      flash: %{},
      metadata_config: Metadata.default_relay_config(),
      media_type: :movie,
      added_item_ids: %{},
      searching: true
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(defaults, assigns)}
  end

  describe "handle_info({:perform_search, query}, socket)" do
    test "a category-restricted scope drops an out-of-bounds search hit" do
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
      socket = stub_socket(%{current_scope: scope})

      {:noreply, updated} = Index.handle_info({:perform_search, "stub"}, socket)

      assert updated.assigns.search_results == []
    end

    test "an unrestricted scope keeps the same hit" do
      socket = stub_socket(%{current_scope: Scope.unrestricted()})

      {:noreply, updated} = Index.handle_info({:perform_search, "stub"}, socket)

      assert Enum.any?(
               updated.assigns.search_results,
               &(&1.title == MetadataStubProvider.movie_title())
             )
    end
  end
end
