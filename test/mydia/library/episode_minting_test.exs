defmodule Mydia.Library.EpisodeMintingTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.{FileIngest, ImportCandidate, MediaFile}
  alias Mydia.{Media, Repo}

  test "an unattended candidate promotion mints and owns a missing episode" do
    library_path = library_path_fixture(%{type: "series"})

    show =
      media_item_fixture(%{
        type: "tv_show",
        tvdb_id: 44_797,
        title: "Minter Show"
      })

    _existing_episode =
      episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

    candidate =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        media_type: "tv_show",
        relative_path: "Minter Show/Season 01/Minter Show - S01E03 - La chorale.mkv",
        parsed_info: %{"type" => "tv_show", "season" => 1, "episodes" => [3]}
      })

    match = %{
      provider_id: Integer.to_string(show.tvdb_id),
      provider_type: :tvdb,
      title: show.title,
      year: show.year,
      match_confidence: 1.0,
      parsed_info: %{type: :tv_show, season: 1, episodes: [3]}
    }

    assert {:promoted, [%MediaFile{episode_id: episode_id, media_item_id: nil}]} =
             FileIngest.ingest(candidate, match, policy: :unattended)

    assert %{id: ^episode_id, title: "La chorale", provider_episode_id: nil} =
             Media.get_episode_by_number(show.id, 1, 3)

    refute Repo.get(ImportCandidate, candidate.id)
  end
end
