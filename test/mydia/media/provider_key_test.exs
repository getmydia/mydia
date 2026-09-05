defmodule Mydia.Media.ProviderKeyTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.ProviderKey
  alias Mydia.Metadata.Structs.SearchResult

  describe "new/3" do
    test "builds a key from a stored type string" do
      assert ProviderKey.new("movie", :tmdb, 550) == {:movie, :tmdb, 550}
      assert ProviderKey.new("tv_show", :tvdb, 550) == {:tv_show, :tvdb, 550}
    end

    test "accepts the type as an atom" do
      assert ProviderKey.new(:tv_show, :tmdb, 42) == {:tv_show, :tmdb, 42}
    end

    test "returns nil when there is no id to key on" do
      assert ProviderKey.new("movie", :tmdb, nil) == nil
    end

    test "raises on a type that cannot reach the column" do
      assert_raise ArgumentError, ~r/invalid media item type/, fn ->
        ProviderKey.new("tvshow", :tmdb, 1)
      end
    end

    test "separates the same number across types and providers" do
      keys =
        for type <- ["movie", "tv_show"], provider <- [:tmdb, :tvdb] do
          ProviderKey.new(type, provider, 550)
        end

      assert length(Enum.uniq(keys)) == 4
    end
  end

  describe "from_card/1" do
    test "keys a search result by its own type, provider and id" do
      card = %SearchResult{provider_id: "550", provider: :tmdb, media_type: :movie}

      assert ProviderKey.from_card(card) == {:movie, :tmdb, 550}
    end

    test "treats an absent provider as TMDB" do
      assert ProviderKey.from_card(%{provider_id: "7", media_type: :tv_show}) ==
               {:tv_show, :tmdb, 7}
    end

    test "accepts an integer provider id and a string media type" do
      assert ProviderKey.from_card(%{provider_id: 7, media_type: "movie"}) == {:movie, :tmdb, 7}
    end

    test "returns nil rather than guessing when the media type is missing" do
      assert ProviderKey.from_card(%{provider_id: "7"}) == nil
      assert ProviderKey.from_card(%{provider_id: "7", media_type: nil}) == nil
    end

    test "returns nil for a non-numeric or absent provider id" do
      assert ProviderKey.from_card(%{provider_id: "not-a-number", media_type: :movie}) == nil
      assert ProviderKey.from_card(%{provider_id: "12abc", media_type: :movie}) == nil
      assert ProviderKey.from_card(%{provider_id: nil, media_type: :movie}) == nil
    end

    test "a movie and a show sharing one TMDB number key apart" do
      movie = %SearchResult{provider_id: "550", provider: :tmdb, media_type: :movie}
      show = %SearchResult{provider_id: "550", provider: :tmdb, media_type: :tv_show}

      refute ProviderKey.from_card(movie) == ProviderKey.from_card(show)
    end
  end
end
