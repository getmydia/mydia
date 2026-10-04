defmodule MydiaWeb.DashboardLive.RestrictedTrendingTest do
  @moduledoc """
  The dashboard's trending rails are provider results, not library rows, so
  `Media.Restrictions` never sees them. They must go through
  `Mydia.Media.RemoteFilter` like Discover's, or a restricted account sees
  out-of-bounds titles on its home page.
  """

  # The metadata cache is one shared ETS table.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers, only: [warm_remote_signals: 3]

  alias Mydia.Accounts.Scope
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.DashboardLive.Index

  setup do
    Cache.clear()
    on_exit(&Cache.clear/0)

    # No genres, no origin: the classifier files this as a plain movie.
    Cache.put("trending_movies", [
      %SearchResult{
        provider_id: "4101",
        provider: :metadata_relay,
        media_type: :movie,
        title: "Nightglass Harbor",
        genre_ids: []
      }
    ])

    # A hit with no genre or origin is classified from a per-title lookup.
    warm_remote_signals({:tmdb, 4101}, :movie, %Mydia.Media.RemoteSignals{category: "movie"})

    :ok
  end

  defp stub_socket(scope) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_scope: scope,
        library_status_map: %{},
        request_status_map: %{}
      }
    }
  end

  defp trending_titles(scope) do
    {:noreply, socket} = Index.handle_info(:load_trending_movies, stub_socket(scope))
    Enum.map(socket.assigns.trending_movies, & &1.title)
  end

  test "a category-restricted scope drops an out-of-bounds trending title" do
    scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

    assert trending_titles(scope) == []
  end

  test "an unrestricted scope keeps it" do
    assert trending_titles(Scope.unrestricted()) == ["Nightglass Harbor"]
  end
end
