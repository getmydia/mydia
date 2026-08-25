defmodule MydiaWeb.DiscoverLive.RestrictedWriteTest do
  @moduledoc """
  `add_with_opts/4`'s `case` had no catch-all and only matched
  `{:error, {:changeset, changeset}}` / `{:error, {:metadata, reason}}`, so a
  bare `{:error, :restricted}` from `Media.Add.from_provider/5` raised
  `CaseClauseError`. This is the primary "Add to Library" button on the
  Discover page, the most common surface a restricted `user`-role account
  hits directly (not through a request).

  Driven through `handle_info/2` directly (the seam
  `AddToLibraryGuardTest` in this same directory already uses for
  `handle_event/3`) rather than a real Bypass round trip: `Metadata.default_relay_config/0`
  is hardcoded inside `MediaAddHelpers.handle_add_media_to_library/6`'s
  caller here, with no per-call override, so the metadata stub's global
  provider registry swap is the available seam.
  """

  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataStub

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.MetadataStubProvider
  alias MydiaWeb.DiscoverLive.Index

  setup :setup_metadata_stub

  defp stub_socket(scope) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_scope: scope,
        library_status_map: %{},
        items: [],
        selected_recommendations: [],
        request_status_map: %{},
        adding_item_ids: MapSet.new([to_string(MetadataStubProvider.movie_tmdb_id())])
      }
    }
  end

  test "an out-of-bounds add flashes a friendly message instead of raising" do
    scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
    socket = stub_socket(scope)

    {:noreply, updated} =
      Index.handle_info(
        {:add_media_to_library, to_string(MetadataStubProvider.movie_tmdb_id()), :movie, nil},
        socket
      )

    assert updated.assigns.flash["error"] == Media.restricted_message()

    refute MapSet.member?(
             updated.assigns.adding_item_ids,
             to_string(MetadataStubProvider.movie_tmdb_id())
           )

    refute Media.get_media_item_by_tmdb(
             Scope.unrestricted(),
             MetadataStubProvider.movie_tmdb_id()
           )
  end
end
