defmodule Mydia.Plugins.Shelves.VerifierTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media.ProviderKey
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Plugins.Shelves.Pick
  alias Mydia.Plugins.Shelves.Verifier

  defp pick(id, attrs \\ %{}) do
    struct!(
      %Pick{media_type: :movie, tmdb_id: id, reason: "Because you finished Ember Tide"},
      attrs
    )
  end

  defp meta(ref, type, attrs \\ %{}) do
    {provider, id} = ref

    struct!(
      %MediaMetadata{
        provider_id: to_string(id),
        provider: provider,
        media_type: type,
        title: "Title #{id}",
        year: 2024,
        poster_path: "/p#{id}.jpg",
        genres: ["Drama"],
        content_rating: "PG"
      },
      attrs
    )
  end

  defp resolver(overrides \\ %{}) do
    fn ref, type ->
      case Map.get(overrides, ref, :default) do
        :default -> {:ok, meta(ref, type)}
        {:meta, attrs} -> {:ok, meta(ref, type, attrs)}
        {:error, _} = error -> error
      end
    end
  end

  defp verify(picks, user, opts \\ []) do
    Verifier.verify(picks, user, Keyword.put_new(opts, :resolver, resolver()))
  end

  test "keeps verified picks in order, with cached title, year and poster" do
    assert {:ok, [first, second, third]} = verify([pick(1), pick(2), pick(3)], user_fixture())

    assert first == %{
             media_type: :movie,
             provider: :tmdb,
             provider_id: 1,
             reason: "Because you finished Ember Tide",
             title: "Title 1",
             year: 2024,
             poster_path: "/p1.jpg"
           }

    assert [second.provider_id, third.provider_id] == [2, 3]
  end

  test "fewer than three survivors is too few" do
    assert {:error, :too_few} = verify([pick(1), pick(2)], user_fixture())
    assert {:error, :too_few} = verify([], user_fixture())
  end

  test "drops what does not resolve" do
    resolver = resolver(%{{:tmdb, 2} => {:error, :not_found}})

    assert {:ok, items} =
             verify([pick(1), pick(2), pick(3), pick(4)], user_fixture(), resolver: resolver)

    assert Enum.map(items, & &1.provider_id) == [1, 3, 4]
  end

  test "when nothing resolves the relay is treated as unavailable" do
    resolver = fn _ref, _type -> {:error, :timeout} end

    assert {:error, :relay_unavailable} =
             verify([pick(1), pick(2), pick(3)], user_fixture(), resolver: resolver)
  end

  test "drops a title already in the library" do
    media_item_fixture(%{title: "Glass Meridian", type: "movie", tmdb_id: 2})

    assert {:ok, items} = verify([pick(1), pick(2), pick(3), pick(4)], user_fixture())
    assert Enum.map(items, & &1.provider_id) == [1, 3, 4]
  end

  test "a movie and a show sharing an id are different titles" do
    media_item_fixture(%{title: "Glass Meridian", type: "movie", tmdb_id: 2})

    assert {:ok, items} =
             verify([pick(1), pick(2, %{media_type: :tv_show}), pick(3)], user_fixture())

    assert Enum.map(items, &{&1.media_type, &1.provider_id}) == [movie: 1, tv_show: 2, movie: 3]
  end

  test "drops a title someone already requested" do
    requester = user_fixture()

    {:ok, _} =
      Mydia.MediaRequests.create_request(Scope.unrestricted(), %{
        title: "The Long Thaw",
        media_type: "movie",
        tmdb_id: 3,
        requester_id: requester.id
      })

    assert {:ok, items} = verify([pick(1), pick(2), pick(3), pick(4)], user_fixture())
    assert Enum.map(items, & &1.provider_id) == [1, 2, 4]
  end

  test "drops dismissed titles and duplicates" do
    dismissed = MapSet.new([ProviderKey.new(:movie, :tmdb, 2)])

    assert {:ok, items} =
             verify([pick(1), pick(2), pick(1), pick(3), pick(4)], user_fixture(),
               dismissed: dismissed
             )

    assert Enum.map(items, & &1.provider_id) == [1, 3, 4]
  end

  test "drops a pick with no usable id or type" do
    picks = [
      pick(1),
      %Pick{media_type: :movie, imdb_id: "tt0000001"},
      %Pick{media_type: nil, tmdb_id: 9},
      %Pick{media_type: :movie, tvdb_id: 9},
      pick(2),
      pick(3)
    ]

    assert {:ok, items} = verify(picks, user_fixture())
    assert Enum.map(items, & &1.provider_id) == [1, 2, 3]
  end

  test "a show may be named by its tvdb id" do
    picks = [pick(1), %Pick{media_type: :tv_show, tvdb_id: 77}, pick(3)]

    assert {:ok, [_, show, _]} = verify(picks, user_fixture())
    assert {show.provider, show.provider_id} == {:tvdb, 77}
  end

  test "cuts to the limit" do
    picks = for n <- 1..20, do: pick(n)

    assert {:ok, items} = verify(picks, user_fixture(), limit: 5)
    assert length(items) == 5
  end

  test "clips and cleans the reason, and keeps a missing one nil" do
    long = String.duplicate("a", 200)

    picks = [
      pick(1, %{reason: long}),
      pick(2, %{reason: "  two\nlines\tand tabs  "}),
      pick(3, %{reason: nil}),
      pick(4, %{reason: "   "})
    ]

    assert {:ok, [a, b, c, d]} = verify(picks, user_fixture())
    assert String.length(a.reason) == 140
    assert b.reason == "two lines and tabs"
    assert c.reason == nil
    assert d.reason == nil
  end

  test "an age limit drops titles rated above it and unrated ones" do
    user = restricted_user_fixture(%{max_content_age: 12})

    resolver =
      resolver(%{
        {:tmdb, 2} => {:meta, %{content_rating: "R"}},
        {:tmdb, 3} => {:meta, %{content_rating: nil}}
      })

    assert {:ok, items} =
             verify([pick(1), pick(2), pick(3), pick(4), pick(5)], user, resolver: resolver)

    assert Enum.map(items, & &1.provider_id) == [1, 4, 5]
  end

  test "a category limit drops titles outside it" do
    user = restricted_user_fixture(%{allowed_categories: ["movie"]})

    resolver =
      resolver(%{{:tmdb, 2} => {:meta, %{genres: ["Animation"], origin_country: ["JP"]}}})

    assert {:ok, items} = verify([pick(1), pick(2), pick(3), pick(4)], user, resolver: resolver)
    assert Enum.map(items, & &1.provider_id) == [1, 3, 4]
  end

  describe "Pick.from_wit/1" do
    test "maps the guest's record" do
      wit = %{item: %{media_type: "tv_show", tmdb_id: 5, tvdb_id: nil, imdb_id: nil}, reason: "r"}

      assert Pick.from_wit(wit) == %Pick{media_type: :tv_show, tmdb_id: 5, reason: "r"}
    end

    test "an unknown type becomes nil rather than an atom" do
      wit = %{item: %{media_type: "podcast", tmdb_id: 5, tvdb_id: nil, imdb_id: nil}, reason: nil}

      assert %Pick{media_type: nil} = Pick.from_wit(wit)
    end
  end
end
