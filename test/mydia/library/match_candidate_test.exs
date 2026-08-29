defmodule Mydia.Library.MatchCandidateTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Library
  alias Mydia.Library.MatchCandidate

  describe "upsert_match_candidate/1" do
    test "creates a candidate for a media file" do
      file = media_file_fixture()

      assert {:ok, candidate} =
               Library.upsert_match_candidate(%{
                 media_file_id: file.id,
                 rank: 0,
                 provider_type: "tmdb",
                 provider_id: "603",
                 title: "The Matrix",
                 year: 1999,
                 media_type: "movie",
                 confidence: 0.95,
                 parsed_info: %{"season" => nil, "episodes" => []}
               })

      assert candidate.title == "The Matrix"
      assert candidate.confidence == 0.95
      assert candidate.attempts == 0
    end

    test "replaces the candidate at the same rank instead of duplicating" do
      file = media_file_fixture()

      base = %{
        media_file_id: file.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "603",
        title: "The Matrix",
        media_type: "movie",
        confidence: 0.95
      }

      assert {:ok, _} = Library.upsert_match_candidate(base)

      assert {:ok, updated} =
               Library.upsert_match_candidate(%{base | title: "The Matrix Revised"})

      assert [only] = Library.list_match_candidates(file.id)
      assert only.id == updated.id
      assert only.title == "The Matrix Revised"
    end

    test "records a failure without a provider match" do
      file = media_file_fixture()

      assert {:ok, candidate} =
               Library.upsert_match_candidate(%{
                 media_file_id: file.id,
                 rank: 0,
                 attempts: 2,
                 last_error: "no_matches_found"
               })

      assert candidate.attempts == 2
      assert candidate.last_error == "no_matches_found"
      assert is_nil(candidate.provider_id)
    end
  end

  describe "delete_match_candidates/1" do
    test "removes every candidate for a file" do
      file = media_file_fixture()

      for rank <- 0..2 do
        {:ok, _} =
          Library.upsert_match_candidate(%{
            media_file_id: file.id,
            rank: rank,
            provider_type: "tmdb",
            provider_id: "#{rank}",
            title: "Result #{rank}",
            media_type: "movie",
            confidence: 0.5
          })
      end

      assert {3, nil} = Library.delete_match_candidates(file.id)
      assert Library.list_match_candidates(file.id) == []
    end
  end

  # `to_match/1` is the single conversion from a stored candidate to the map
  # `FileIngest.ingest/3` expects. It carries two traps that predate it.
  #
  # `provider_type` is free text with no inclusion validation, so it can hold a
  # value this VM has never interned as an atom.
  #
  # `parsed_info` round-trips through JSON, so its keys and its "type" value come
  # back as strings, while `MetadataEnricher.determine_media_type/1` matches atom
  # keys and an atom value. Passing the stored map through unchanged silently
  # classifies every file as a movie.
  describe "to_match/1" do
    defp candidate(overrides \\ %{}) do
      struct!(
        %MatchCandidate{
          provider_type: "tmdb",
          provider_id: "603",
          title: "The Matrix",
          year: 1999,
          media_type: "movie",
          confidence: 0.97,
          parsed_info: %{}
        },
        overrides
      )
    end

    test "carries the provider fields and confidence through" do
      match = MatchCandidate.to_match(candidate())

      assert match.provider_id == "603"
      assert match.provider_type == :tmdb
      assert match.title == "The Matrix"
      assert match.year == 1999
      assert match.match_confidence == 0.97
    end

    test "a cached candidate is never a local-database match" do
      # It was written from a provider lookup, so auto-import counting must see
      # it as externally sourced.
      assert MatchCandidate.to_match(candidate()).from_local_db == false
    end

    test "maps the two real providers and defaults anything else" do
      assert MatchCandidate.to_match(candidate(%{provider_type: "tvdb"})).provider_type == :tvdb
      assert MatchCandidate.to_match(candidate(%{provider_type: "tmdb"})).provider_type == :tmdb
    end

    test "an unknown provider_type never raises" do
      # String.to_existing_atom/1 on this column could raise for a value this VM
      # has never interned. The column has no inclusion validation.
      match = MatchCandidate.to_match(candidate(%{provider_type: "wikidata-scraper"}))

      assert match.provider_type == :tvdb
    end

    test "a nil provider_type defaults rather than crashing" do
      assert MatchCandidate.to_match(candidate(%{provider_type: nil})).provider_type == :tvdb
    end

    test "rebuilds parsed_info with atom keys and an atom type" do
      # The stored map has string keys after its JSON round trip.
      # MetadataEnricher.determine_media_type/1 matches atom keys, so passing the
      # stored shape through would classify this TV file as a movie.
      match =
        MatchCandidate.to_match(
          candidate(%{
            media_type: "tv_show",
            parsed_info: %{"season" => 2, "episodes" => [5, 6], "type" => "tv_show"}
          })
        )

      assert match.parsed_info == %{type: :tv_show, season: 2, episodes: [5, 6]}
    end

    test "a movie candidate gets the movie type and empty episodes" do
      match = MatchCandidate.to_match(candidate(%{media_type: "movie", parsed_info: %{}}))

      assert match.parsed_info == %{type: :movie, season: nil, episodes: []}
    end

    test "a nil parsed_info is treated as an empty one" do
      match = MatchCandidate.to_match(candidate(%{parsed_info: nil}))

      assert match.parsed_info == %{type: :movie, season: nil, episodes: []}
    end
  end
end
