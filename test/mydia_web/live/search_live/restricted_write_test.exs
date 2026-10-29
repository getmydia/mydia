defmodule MydiaWeb.SearchLive.RestrictedWriteTest do
  @moduledoc """
  `create_media_item_from_metadata/4` used to call `changeset.errors` on
  whatever `Media.create_media_item/2` returned as its error, which crashed
  with `BadMapError` the moment that error became the bare atom `:restricted`
  instead of an `Ecto.Changeset`. It runs inside a `start_async` task, so the
  crash was contained by the task supervisor rather than taking the LiveView
  process down, but it was still an unhandled exception on the primary
  "paste a release name" add path.

  Made public specifically so this can be pinned without driving a real
  metadata fetch through `start_async/3`.
  """

  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts.Scope
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Metadata.Structs.MediaMetadata
  alias MydiaWeb.SearchLive.ReleaseAdd

  # Creating a movie asks the relay whether it belongs to a franchise (#1293).
  # The details cache is global and this module is async, so each test warms
  # an id of its own; a shared one like 1 collides with other tests' entries.
  setup do
    provider_id = unique_provider_id()
    warm_movie_details_cache(provider_id)
    %{provider_id: to_string(provider_id)}
  end

  defp cartoon_only_scope do
    Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
  end

  defp parsed(attrs) do
    struct!(%ParsedFileInfo{type: :movie, original_filename: "x", confidence: 1.0}, attrs)
  end

  defp metadata(attrs) do
    struct!(MediaMetadata, Keyword.merge([provider: :tmdb, media_type: :movie], attrs))
  end

  test "an out-of-bounds release refuses cleanly instead of raising", %{provider_id: id} do
    assert {:error, :restricted} =
             ReleaseAdd.create_media_item_from_metadata(
               cartoon_only_scope(),
               parsed(title: "Live Action Thriller", year: 2024),
               metadata(
                 title: "Live Action Thriller",
                 genres: ["Thriller"],
                 content_rating: "R",
                 provider_id: id
               )
             )
  end

  test "an in-bounds release still creates normally", %{provider_id: id} do
    assert {:ok, item, :created} =
             ReleaseAdd.create_media_item_from_metadata(
               cartoon_only_scope(),
               parsed(title: "Animated Feature", year: 2024),
               metadata(
                 title: "Animated Feature",
                 genres: ["Animation"],
                 content_rating: "G",
                 provider_id: id
               )
             )

    assert item.category == "cartoon_movie"
  end

  test "an unrestricted scope is unaffected", %{provider_id: id} do
    assert {:ok, _item, :created} =
             ReleaseAdd.create_media_item_from_metadata(
               Scope.unrestricted(),
               parsed(title: "Anything At All", year: 2024),
               metadata(
                 title: "Anything At All",
                 genres: ["Thriller"],
                 content_rating: "R",
                 provider_id: id
               )
             )
  end
end
