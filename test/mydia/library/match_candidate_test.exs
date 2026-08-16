defmodule Mydia.Library.MatchCandidateTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Library

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
end
