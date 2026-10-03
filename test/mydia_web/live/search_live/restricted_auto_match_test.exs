defmodule MydiaWeb.SearchLive.RestrictedAutoMatchTest.TwoHitProvider do
  @moduledoc false
  # The stub catalog has one movie. This serves it plus a second hit, so the
  # filter can leave exactly one of two.

  alias Mydia.Metadata.Structs.SearchResult
  alias Mydia.MetadataStubProvider

  def other_id, do: 8_800_123

  def search(config, query, opts) do
    with {:ok, [movie]} <- MetadataStubProvider.search(config, query, opts) do
      other = %SearchResult{
        movie
        | provider_id: to_string(other_id()),
          id: other_id(),
          title: "Other Stub Movie",
          original_title: "Other Stub Movie"
      }

      {:ok, [movie, other]}
    end
  end

  defdelegate fetch_by_ref(config, ref, opts), to: MetadataStubProvider
end

defmodule MydiaWeb.SearchLive.RestrictedAutoMatchTest do
  @moduledoc """
  Pasting a release name on `/search` auto-matches it to a catalog title.
  Filtering for a restricted account must not change which branch runs: an
  ambiguous release still goes to disambiguation, and a lone out-of-bounds hit
  is no match at all.
  """

  # The stub provider registry and the metadata cache are global.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers, only: [warm_remote_signals: 3]
  import Mydia.MetadataStub

  alias Mydia.Accounts.Scope
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Media.RemoteSignals
  alias Mydia.Metadata.Provider.Registry
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.MetadataStubProvider
  alias MydiaWeb.SearchLive.Index, as: SearchLive
  alias MydiaWeb.SearchLive.RestrictedAutoMatchTest.TwoHitProvider

  setup :setup_metadata_stub

  setup do
    warm_remote_signals(
      {:tmdb, MetadataStubProvider.movie_tmdb_id()},
      :movie,
      %RemoteSignals{category: "movie"}
    )

    warm_remote_signals(
      {:tmdb, TwoHitProvider.other_id()},
      :movie,
      %RemoteSignals{category: "cartoon_movie"}
    )

    :ok
  end

  defp scope_allowing(categories) do
    Scope.for_user(restricted_user_fixture(%{allowed_categories: categories}))
  end

  defp parsed do
    %ParsedFileInfo{type: :movie, original_filename: "x", confidence: 1.0, title: "Stub"}
  end

  defp items, do: Mydia.Repo.aggregate(Mydia.Media.MediaItem, :count)

  test "several hits with one left after filtering still go to disambiguation" do
    Registry.register(:metadata_relay, TwoHitProvider)
    before = items()

    assert {:ok, {:multiple_matches, [only], :movie}} =
             SearchLive.search_and_fetch_metadata(scope_allowing(["movie"]), parsed())

    assert only.title == MetadataStubProvider.movie_title()
    assert items() == before
  end

  test "one hit that is out of bounds is no match" do
    before = items()

    assert {:error, :no_metadata_match} =
             SearchLive.search_and_fetch_metadata(scope_allowing(["cartoon_movie"]), parsed())

    assert items() == before
  end

  test "one hit that is in bounds is fetched and linked as before" do
    assert {:ok, %MediaMetadata{} = metadata} =
             SearchLive.search_and_fetch_metadata(scope_allowing(["movie"]), parsed())

    assert metadata.title == MetadataStubProvider.movie_title()
  end

  test "an unrestricted scope sees both hits in disambiguation" do
    Registry.register(:metadata_relay, TwoHitProvider)

    assert {:ok, {:multiple_matches, [_, _], :movie}} =
             SearchLive.search_and_fetch_metadata(Scope.unrestricted(), parsed())
  end
end
