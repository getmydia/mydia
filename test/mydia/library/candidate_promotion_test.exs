defmodule Mydia.Library.CandidatePromotionTest do
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.Library.{CandidatePromotion, ImportCandidate, MediaFile}
  alias Mydia.Repo

  setup :setup_metadata_stub

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

  test "rolls back a file inserted before a later candidate cannot be owned" do
    library_path = library_path_fixture(%{type: "mixed"})
    movie = media_item_fixture(%{type: "movie", tmdb_id: 60_305})

    first =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        media_type: "movie",
        parsed_info: %{"type" => "movie"}
      })

    second =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        anchor_key: first.anchor_key,
        media_type: "tv_show",
        parsed_info: %{"type" => "tv_show", "season" => 1, "episodes" => [1]}
      })

    assert {:error, {:incompatible_media_type, "tv_show", "movie"}} =
             CandidatePromotion.promote_group([first, second], movie_match(movie),
               config: stub_config()
             )

    assert Repo.get(ImportCandidate, first.id)
    assert Repo.get(ImportCandidate, second.id)
    refute Repo.exists?(from f in MediaFile, where: f.library_path_id == ^library_path.id)
  end

  test "rejects a candidate changed after its match was prepared" do
    library_path = library_path_fixture(%{type: "movies"})
    movie = media_item_fixture(%{type: "movie", tmdb_id: 60_306})

    candidate =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        media_type: "movie",
        parsed_info: %{"type" => "movie"}
      })

    assert {:ok, _changed} =
             Mydia.ImportCandidates.upsert(%{
               library_path_id: candidate.library_path_id,
               relative_path: candidate.relative_path,
               anchor_key: candidate.anchor_key,
               size: candidate.size + 1,
               discovered_at: candidate.discovered_at
             })

    candidate_id = candidate.id

    assert {:error, {:stale_candidate, ^candidate_id}} =
             CandidatePromotion.promote_group([candidate], movie_match(movie),
               config: stub_config()
             )

    refute Repo.exists?(from f in MediaFile, where: f.library_path_id == ^library_path.id)
  end

  test "adopts a matching sidecar only after the owned file commits" do
    dir = Path.join(System.tmp_dir!(), "promotion-sidecar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    library_path = library_path_fixture(%{type: "movies", path: dir})
    movie = media_item_fixture(%{type: "movie", tmdb_id: 60_307})
    File.write!(Path.join(dir, "Movie.mkv"), "video")
    File.write!(Path.join(dir, "Movie.en.srt"), "1\n00:00:01,000 --> 00:00:02,000\nHello.\n")

    candidate =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        relative_path: "Movie.mkv",
        media_type: "movie",
        parsed_info: %{"type" => "movie"}
      })

    assert {:ok, [media_file]} =
             CandidatePromotion.promote_group([candidate], movie_match(movie),
               config: stub_config()
             )

    assert [%{language: "en", origin: "sidecar"}] = Mydia.Subtitles.list_subtitles(media_file.id)
  end

  test "an unrelated write succeeds while provider enrichment is blocked" do
    library_path = library_path_fixture(%{type: "series"})

    candidate =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        media_type: "tv_show",
        parsed_info: %{"type" => "tv_show", "season" => 1, "episodes" => [1]}
      })

    match = %{
      provider_id: Integer.to_string(Mydia.MetadataStubProvider.series_tvdb_id()),
      provider_type: :tvdb,
      title: Mydia.MetadataStubProvider.series_title(),
      match_confidence: 1.0,
      parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
    }

    ref = Mydia.MetadataStubProvider.block_next_season_fetch(self())

    task =
      Task.async(fn ->
        CandidatePromotion.promote_group([candidate], match,
          config: Mydia.Metadata.default_relay_config()
        )
      end)

    assert_receive {:metadata_season_fetch_started, ^ref, worker}, 1_000

    assert {:ok, _unrelated} =
             Mydia.Settings.create_library_path(%{
               path: "/tmp/unrelated-#{System.unique_integer([:positive])}",
               type: :movies
             })

    send(worker, {:release_metadata_season_fetch, ref})
    assert {:ok, [%MediaFile{episode_id: episode_id}]} = Task.await(task, 2_000)
    assert episode_id
  end

  test "simultaneous promotion attempts create one owned file" do
    library_path = library_path_fixture(%{type: "movies"})
    movie = media_item_fixture(%{type: "movie", tmdb_id: 60_311})

    candidate =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        media_type: "movie",
        parsed_info: %{"type" => "movie"}
      })

    parent = self()

    promote = fn ->
      send(parent, :promotion_ready)

      receive do: (:start_promotion ->
                     CandidatePromotion.promote_group([candidate], movie_match(movie),
                       config: stub_config()
                     ))
    end

    first = Task.async(promote)
    second = Task.async(promote)

    assert_receive :promotion_ready, 1_000
    assert_receive :promotion_ready, 1_000
    send(first.pid, :start_promotion)
    send(second.pid, :start_promotion)

    results = [Task.await(first, 2_000), Task.await(second, 2_000)]
    assert Enum.count(results, &match?({:ok, [_]}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert Repo.aggregate(MediaFile, :count) == 1
    refute Repo.get(ImportCandidate, candidate.id)
  end
end
