defmodule MydiaWeb.SearchLive.RestrictedWriteTest do
  @moduledoc """
  `create_media_item_from_metadata/3` used to call `changeset.errors` on
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

  alias Mydia.Accounts.Scope
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Metadata.Structs.MediaMetadata
  alias MydiaWeb.SearchLive.Index, as: SearchLive

  defp cartoon_only_scope do
    Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
  end

  defp parsed(attrs) do
    struct!(%ParsedFileInfo{type: :movie, original_filename: "x", confidence: 1.0}, attrs)
  end

  defp metadata(attrs) do
    struct!(%MediaMetadata{provider_id: "1", provider: :tmdb, media_type: :movie}, attrs)
  end

  test "an out-of-bounds release refuses cleanly instead of raising" do
    assert {:error, :restricted} =
             SearchLive.create_media_item_from_metadata(
               cartoon_only_scope(),
               parsed(title: "Live Action Thriller", year: 2024),
               metadata(title: "Live Action Thriller", genres: ["Thriller"], content_rating: "R")
             )
  end

  test "an in-bounds release still creates normally" do
    assert {:ok, item} =
             SearchLive.create_media_item_from_metadata(
               cartoon_only_scope(),
               parsed(title: "Animated Feature", year: 2024),
               metadata(title: "Animated Feature", genres: ["Animation"], content_rating: "G")
             )

    assert item.category == "cartoon_movie"
  end

  test "an unrestricted scope is unaffected" do
    assert {:ok, _item} =
             SearchLive.create_media_item_from_metadata(
               Scope.unrestricted(),
               parsed(title: "Anything At All", year: 2024),
               metadata(title: "Anything At All", genres: ["Thriller"], content_rating: "R")
             )
  end
end
