defmodule Mydia.Library.CandidatePromotionTest do
  use Mydia.DataCase, async: true

  import Ecto.Query
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.{CandidatePromotion, ImportCandidate, MediaFile}
  alias Mydia.Repo

  defp movie_match(movie) do
    %{
      provider_id: Integer.to_string(movie.tmdb_id),
      provider_type: :tmdb,
      title: movie.title,
      year: movie.year,
      match_confidence: 0.95,
      parsed_info: %{type: :movie, season: nil, episodes: []}
    }
  end

  defp tv_match(show) do
    %{
      provider_id: Integer.to_string(show.tvdb_id),
      provider_type: :tvdb,
      title: show.title,
      year: show.year,
      match_confidence: 0.95,
      parsed_info: %{type: :tv_show, season: 99, episodes: [1]}
    }
  end

  defp stub_config, do: Mydia.Metadata.default_relay_config()

  test "promotes a movie group in one ownership transaction" do
    library_path = library_path_fixture(%{type: "movies"})
    movie = media_item_fixture(%{type: "movie", tmdb_id: 60_300})

    candidate =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        media_type: "movie",
        parsed_info: %{"type" => "movie"}
      })

    assert {:ok, [%MediaFile{media_item_id: item_id, episode_id: nil}]} =
             CandidatePromotion.promote_group([candidate], movie_match(movie),
               config: stub_config()
             )

    assert item_id == movie.id
    refute Repo.get(ImportCandidate, candidate.id)
  end

  test "a missing TV episode leaves every candidate in the group" do
    library_path = library_path_fixture(%{type: "series"})
    show = media_item_fixture(%{type: "tv_show", tvdb_id: 13_960})

    first =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        media_type: "tv_show",
        parsed_info: %{"type" => "tv_show", "season" => 99, "episodes" => [1]}
      })

    second =
      import_candidate_fixture(%{
        library_path_id: first.library_path_id,
        anchor_key: first.anchor_key,
        media_type: "tv_show",
        parsed_info: %{"type" => "tv_show", "season" => 99, "episodes" => [1]}
      })

    assert {:error, _reason} =
             CandidatePromotion.promote_group([first, second], tv_match(show),
               config: stub_config()
             )

    assert Repo.get(ImportCandidate, first.id)
    assert Repo.get(ImportCandidate, second.id)

    refute Repo.exists?(from f in MediaFile, where: f.library_path_id == ^first.library_path_id)
  end
end
