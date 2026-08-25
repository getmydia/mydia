defmodule MydiaWeb.Api.MediaControllerTest do
  @moduledoc """
  `perform_manual_match/5` used to fold every `Media.update_media_item/4`
  error into `json(%{error: "Failed to update media item: \#{inspect(reason)}"})`,
  which is harmless for an `Ecto.Changeset` but literally returned the string
  ":restricted" once the update could fail that way -- an internal atom
  leaking straight into the API response body.
  """

  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Metadata.Provider
  alias Mydia.Metadata.Structs.{EpisodeData, ImagesResponse, MediaMetadata}

  # media_controller.ex's extract_year/1 reads metadata.release_date.year, so
  # unlike most other test doubles in this suite it needs a real %Date{}
  # rather than the ISO string most providers store on the struct.
  defmodule LiveActionProvider do
    @behaviour Mydia.Metadata.Provider

    @impl true
    def test_connection(_config), do: {:ok, %{status: "ok"}}

    @impl true
    def search(_config, _query, _opts), do: {:ok, []}

    @impl true
    def fetch_by_id(_config, id, _opts) do
      {:ok,
       %MediaMetadata{
         provider_id: id,
         provider: :metadata_relay,
         media_type: :movie,
         id: String.to_integer(id),
         title: "Live Action Rematch",
         release_date: ~D[2015-06-01],
         genres: ["Action"]
       }}
    end

    @impl true
    def fetch_images(_config, _id, _opts),
      do: {:ok, ImagesResponse.new(%{posters: [], backdrops: [], logos: []})}

    @impl true
    def fetch_season(_config, _id, _season, _opts), do: {:ok, %{}}

    @impl true
    def fetch_trending(_config, _opts), do: {:ok, []}
  end

  setup do
    Provider.Registry.register(:metadata_relay, LiveActionProvider)
    on_exit(fn -> Mydia.Metadata.register_providers() end)
    :ok
  end

  defp cartoon_movie do
    {:ok, item} =
      Media.create_media_item(
        Scope.system(),
        %{
          type: "movie",
          title: "Cartoon Original",
          year: 2020,
          tmdb_id: System.unique_integer([:positive]),
          metadata: %MediaMetadata{
            provider_id: "9001",
            provider: :tmdb,
            media_type: :movie,
            genres: ["Animation"]
          }
        },
        skip_episode_refresh: true
      )

    assert item.category == "cartoon_movie"
    item
  end

  test "manually matching a restricted title returns a friendly message, not a raw atom",
       %{conn: conn} do
    movie = cartoon_movie()

    restricted =
      restricted_user_fixture(%{role: "user", allowed_categories: ["cartoon_movie"]})

    conn =
      conn
      |> log_in_user(restricted)
      |> post(~p"/api/v1/media/#{movie.id}/match", %{
        "provider_id" => "12345",
        "provider_type" => "tmdb"
      })

    assert %{"error" => message} = json_response(conn, 403)
    assert message == Media.restricted_message()
    refute message =~ ":restricted"

    # The stored item is untouched -- still the animated original, not the
    # live-action match that was refused.
    unchanged = Media.get_media_item!(Scope.unrestricted(), movie.id)
    assert unchanged.category == "cartoon_movie"
  end

  test "a successful match serializes without raising", %{conn: conn} do
    {:ok, movie} =
      Media.create_media_item(
        Scope.system(),
        %{
          type: "movie",
          title: "Placeholder Title",
          year: 1999,
          tmdb_id: System.unique_integer([:positive]),
          metadata: %MediaMetadata{
            provider_id: "1",
            provider: :tmdb,
            media_type: :movie,
            genres: ["Drama"]
          }
        },
        skip_episode_refresh: true
      )

    conn =
      conn
      |> log_in_user(create_test_user())
      |> post(~p"/api/v1/media/#{movie.id}/match", %{
        "provider_id" => "12345",
        "provider_type" => "tmdb"
      })

    assert %{"data" => data} = json_response(conn, 200)

    # These used to raise KeyError: serialize_media_item/1 read them straight
    # off %MediaItem{}, which carries no such top-level columns, instead of
    # off media_item.metadata (see LiveActionProvider's fetch_by_id/3 above).
    assert data["title"] == "Live Action Rematch"
    assert data["year"] == 2015
    assert data["genres"] == ["Action"]
    assert data["overview"] == nil
    assert data["poster_url"] == nil
    assert data["backdrop_url"] == nil
    assert data["runtime"] == nil
    assert data["status"] == nil
  end

  test "an episode with metadata serializes without raising", %{conn: conn} do
    {:ok, show} =
      Media.create_media_item(
        Scope.system(),
        %{type: "tv_show", title: "Stub Series", year: 2010},
        skip_episode_refresh: true
      )

    {:ok, _episode} =
      Media.create_episode(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
        title: "Pilot",
        metadata: %EpisodeData{
          season_number: 1,
          episode_number: 1,
          overview: "The one where it all begins.",
          still_path: "/pilot-still.jpg"
        }
      })

    conn =
      conn
      |> log_in_user(create_test_user())
      |> get(~p"/api/v1/media/#{show.id}")

    # serialize_episodes/1 read episode.overview and episode.still_url
    # directly off %Episode{}, which -- like MediaItem -- carries neither as a
    # top-level column; both live under episode.metadata.
    assert %{"data" => %{"episodes" => [episode]}} = json_response(conn, 200)
    assert episode["overview"] == "The one where it all begins."
    assert episode["still_url"] =~ "pilot-still.jpg"
  end
end
