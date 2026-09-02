defmodule Mydia.Metadata.RefTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Ref
  alias Mydia.Metadata.Structs.SearchResult

  describe "parse/1" do
    test "parses both allowlisted tags" do
      assert Ref.parse("tmdb:63639") == {:ok, {:tmdb, 63_639}}
      assert Ref.parse("tvdb:280619") == {:ok, {:tvdb, 280_619}}
    end

    test "rejects an unknown tag without creating an atom" do
      assert Ref.parse("imdb:tt3230854") == :error
      assert Ref.parse("definitely_not_a_provider:1") == :error
    end

    test "rejects ids that are not positive integers" do
      assert Ref.parse("tmdb:") == :error
      assert Ref.parse("tmdb:abc") == :error
      assert Ref.parse("tmdb:12abc") == :error
      assert Ref.parse("tmdb:0") == :error
      assert Ref.parse("tmdb:-5") == :error
    end

    test "rejects a bare id with no tag" do
      assert Ref.parse("280619") == :error
    end
  end

  describe "to_param/1" do
    test "round trips through parse/1" do
      for ref <- [{:tmdb, 63_639}, {:tvdb, 280_619}] do
        assert Ref.parse(Ref.to_param(ref)) == {:ok, ref}
      end
    end
  end

  describe "accessors" do
    test "provider/1 and id/1 destructure the ref" do
      assert Ref.provider({:tvdb, 280_619}) == :tvdb
      assert Ref.id({:tvdb, 280_619}) == 280_619
    end
  end

  describe "from_search_result/1" do
    test "keeps an explicit tvdb provenance" do
      result = %SearchResult{provider_id: "280619", provider: :tvdb, media_type: :tv_show}

      assert Ref.from_search_result(result) == {:tvdb, 280_619}
    end

    test "maps the legacy :metadata_relay config type to :tmdb" do
      result = %SearchResult{
        provider_id: "63639",
        provider: :metadata_relay,
        media_type: :tv_show
      }

      assert Ref.from_search_result(result) == {:tmdb, 63_639}
    end

    test "accepts an already honest :tmdb provenance" do
      result = %SearchResult{provider_id: "63639", provider: :tmdb, media_type: :movie}

      assert Ref.from_search_result(result) == {:tmdb, 63_639}
    end

    test "raises on a provider_id that is not an integer" do
      result = %SearchResult{provider_id: "series-280619", provider: :tvdb, media_type: :tv_show}

      assert_raise ArgumentError, fn -> Ref.from_search_result(result) end
    end
  end
end
