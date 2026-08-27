defmodule MydiaWeb.MediaLive.Show.RestrictedWriteEventsTest do
  @moduledoc """
  `EpisodeEvents.toggle_monitored/2` bare-matched
  `{:ok, updated_item} = Media.update_media_item(...)`, which raised
  `MatchError` the moment that call could return `{:error, :restricted}`.
  `CategoryEvents.save_category/2` and `reset_category_to_auto/2` only had
  `case` clauses for `{:ok, _}` and `{:error, %Ecto.Changeset{}}`, so the same
  return value raised `CaseClauseError` instead.

  These are reachable if a scope's restriction narrows (or the item's
  metadata changes) after a socket already has the item loaded and visible --
  a stale-write race the read-side gate on `get_media_item!/3` cannot prevent
  on its own, which is exactly why `Media.update_media_item/4` carries its own
  guard. Built with a hand-constructed socket, the same seam
  `FranchiseEventsTest` uses, since reproducing the race through a live mount
  would require narrowing a restriction mid-session.
  """

  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Metadata.Structs.MediaMetadata
  alias MydiaWeb.MediaLive.Show.CategoryEvents
  alias MydiaWeb.MediaLive.Show.EpisodeEvents

  defp stub_socket(assigns) do
    defaults = %{
      __changed__: %{},
      flash: %{},
      current_user: user_fixture(%{role: "user"})
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(defaults, assigns)}
  end

  # An out-of-bounds movie visible only through this scope's own restriction
  # window: created via Scope.system() (unrestricted), so creation itself is
  # unaffected, then judged against a scope that would not have shown it.
  defp out_of_bounds_movie_and_scope do
    movie =
      media_item_fixture(%{
        metadata: %MediaMetadata{
          provider_id: "1",
          provider: :tmdb,
          media_type: :movie,
          genres: ["Thriller"],
          content_rating: "R"
        }
      })

    scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
    {movie, scope}
  end

  describe "EpisodeEvents.toggle_monitored/2" do
    test "refuses cleanly with a friendly flash instead of a MatchError" do
      {movie, scope} = out_of_bounds_movie_and_scope()
      socket = stub_socket(%{current_scope: scope, media_item: movie})

      {:noreply, updated} = EpisodeEvents.toggle_monitored(%{}, socket)

      assert updated.assigns.flash["error"] ==
               "This title is outside what your account is allowed to access."
    end

    test "an in-bounds item still toggles normally" do
      movie =
        media_item_fixture(%{
          monitored: true,
          metadata: %MediaMetadata{
            provider_id: "2",
            provider: :tmdb,
            media_type: :movie,
            genres: ["Animation"],
            content_rating: "G"
          }
        })

      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
      socket = stub_socket(%{current_scope: scope, media_item: movie})

      {:noreply, updated} = EpisodeEvents.toggle_monitored(%{}, socket)

      assert updated.assigns.media_item.monitored == false
      refute Map.has_key?(updated.assigns.flash, "error")
    end
  end

  describe "CategoryEvents.save_category/2" do
    test "refuses cleanly with a friendly flash instead of a CaseClauseError" do
      {movie, scope} = out_of_bounds_movie_and_scope()
      socket = stub_socket(%{current_scope: scope, media_item: movie})

      {:noreply, updated} =
        CategoryEvents.save_category(
          %{"media_item" => %{"category" => "movie", "override" => "true"}},
          socket
        )

      assert updated.assigns.flash["error"] ==
               "This title is outside what your account is allowed to access."
    end
  end

  describe "CategoryEvents.reset_category_to_auto/2" do
    test "refuses cleanly with a friendly flash instead of a CaseClauseError" do
      {movie, scope} = out_of_bounds_movie_and_scope()
      socket = stub_socket(%{current_scope: scope, media_item: movie})

      {:noreply, updated} = CategoryEvents.reset_category_to_auto(%{}, socket)

      assert updated.assigns.flash["error"] ==
               "This title is outside what your account is allowed to access."
    end
  end
end
