defmodule Mydia.Library.CandidateSuggestionsTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.{CandidateSuggestion, CandidateSuggestions}
  alias Mydia.Repo

  defp movie do
    media_item_fixture(%{
      type: "movie",
      title: "Zephyr Station",
      year: 2030,
      tmdb_id: 900_301,
      metadata_source: :tmdb
    })
  end

  defp ids(suggestions), do: Enum.map(suggestions, & &1.candidate.id)

  test "ranks a parked file with the same provider id first" do
    lp = library_path_fixture(%{type: "movies"})
    movie = movie()

    look_alike =
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: "Zephyr Station (2030)/Zephyr.Station.2030.mkv"
      )

    parked =
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: "misc/zs.mkv",
        provider_type: "tmdb",
        provider_id: "900301",
        dismissed_at: ~U[2026-09-01 00:00:00Z]
      )

    assert [%CandidateSuggestion{reasons: reasons} = first | rest] =
             CandidateSuggestions.suggest_for(movie)

    assert first.candidate.id == parked.id
    assert :same_provider in reasons
    assert look_alike.id in ids(rest)
  end

  test "reports title and year reasons from the filename" do
    lp = library_path_fixture(%{type: "movies"})
    movie = movie()

    c =
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: "Zephyr Station (2030)/Zephyr.Station.2030.1080p.mkv"
      )

    assert [%{candidate: %{id: id}, reasons: reasons}] = CandidateSuggestions.suggest_for(movie)
    assert id == c.id
    assert {:year, 2030} in reasons
    assert Enum.any?(reasons, &match?({:title, s} when s >= 0.8, &1))
  end

  test "drops implausible candidates unless a query is given" do
    lp = library_path_fixture(%{type: "movies"})
    movie = movie()

    unrelated =
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: "Quillmere Harbor (2019)/Quillmere.Harbor.2019.1080p.mkv"
      )

    assert CandidateSuggestions.suggest_for(movie) == []
    assert [%{candidate: %{id: id}}] = CandidateSuggestions.suggest_for(movie, query: "quill")
    assert id == unrelated.id
  end

  test "a same-year candidate with an unrelated title is dropped" do
    lp = library_path_fixture(%{type: "movies"})
    movie = movie()

    import_candidate_fixture(
      library_path_id: lp.id,
      relative_path: "Emberline (2030)/Emberline.2030.mkv"
    )

    assert CandidateSuggestions.suggest_for(movie) == []
  end

  test "excludes incompatible library types, queued and wrong-type candidates" do
    movie = movie()
    series_lp = library_path_fixture(%{type: "series"})
    movies_lp = library_path_fixture(%{type: "movies"})
    rel = "Zephyr Station (2030)/Zephyr.Station.2030.mkv"

    import_candidate_fixture(library_path_id: series_lp.id, relative_path: rel)

    import_candidate_fixture(
      library_path_id: movies_lp.id,
      relative_path: rel,
      queued_op: "accept"
    )

    import_candidate_fixture(
      library_path_id: movies_lp.id,
      relative_path: "Zephyr Station (2030)/tv.mkv",
      media_type: "tv_show"
    )

    assert CandidateSuggestions.suggest_for(movie) == []
  end

  test "excludes disabled library paths" do
    lp = library_path_fixture(%{type: "movies", disabled: true})
    movie = movie()

    import_candidate_fixture(
      library_path_id: lp.id,
      relative_path: "Zephyr Station (2030)/Zephyr.Station.2030.mkv"
    )

    assert CandidateSuggestions.suggest_for(movie) == []
  end

  test "an episode ranks its own SxxEyy first" do
    lp = library_path_fixture(%{type: "series"})
    show = media_item_fixture(%{type: "tv_show", title: "Lantern Coast", tvdb_id: 900_302})
    episode = episode_fixture(media_item_id: show.id, season_number: 2, episode_number: 4)

    wrong =
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: "Lantern Coast/Lantern.Coast.S02E05.mkv",
        parsed_info: %{"season" => 2, "episodes" => [5]}
      )

    right =
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: "Lantern Coast/Lantern.Coast.S02E04.mkv",
        parsed_info: %{"season" => 2, "episodes" => [4]}
      )

    episode = Repo.preload(episode, :media_item)
    assert [first, second] = CandidateSuggestions.suggest_for(episode)
    assert first.candidate.id == right.id
    assert {:episode, 2, 4} in first.reasons
    assert second.candidate.id == wrong.id
  end

  test "an episode only gets same_provider on the file matching the episode" do
    lp = library_path_fixture(%{type: "series"})
    show = media_item_fixture(%{type: "tv_show", title: "Lantern Coast", tvdb_id: 900_302})
    episode = episode_fixture(media_item_id: show.id, season_number: 2, episode_number: 4)

    mk = fn n ->
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: "Lantern Coast/Lantern.Coast.S02E0#{n}.mkv",
        provider_type: "tvdb",
        provider_id: "900302",
        parsed_info: %{"season" => 2, "episodes" => [n]}
      )
    end

    right = mk.(4)
    wrong = mk.(5)

    episode = Repo.preload(episode, :media_item)
    assert [first, second] = CandidateSuggestions.suggest_for(episode)
    assert first.candidate.id == right.id
    assert :same_provider in first.reasons
    assert second.candidate.id == wrong.id
    refute :same_provider in second.reasons
  end

  test "respects :limit" do
    lp = library_path_fixture(%{type: "movies"})
    movie = movie()

    for n <- 1..3 do
      import_candidate_fixture(
        library_path_id: lp.id,
        relative_path: "Zephyr Station (2030)/part#{n}.Zephyr.Station.2030.mkv"
      )
    end

    assert length(CandidateSuggestions.suggest_for(movie, limit: 2)) == 2
  end
end
