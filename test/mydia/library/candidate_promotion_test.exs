defmodule Mydia.Library.CandidatePromotionTest do
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.Events.Event
  alias Mydia.Library.{CandidatePromotion, ImportCandidate, MediaFile}
  alias Mydia.Media.{Episode, MediaItem}
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

  defp import_candidate_with_id!(id, attrs) do
    attrs = Map.new(attrs)

    %ImportCandidate{id: id}
    |> ImportCandidate.changeset(attrs)
    |> Repo.insert!()
  end

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

    # CandidatePromotion orders ownership writes by ID. These explicit IDs make
    # the movie insert happen before the incompatible TV candidate fails.
    first =
      import_candidate_with_id!("00000000-0000-4000-8000-000000000001", %{
        library_path_id: library_path.id,
        relative_path: "atomic-first.mkv",
        anchor_key: "atomic-group",
        size: 1_000_000_000,
        discovered_at: DateTime.utc_now() |> DateTime.truncate(:second),
        media_type: "movie",
        parsed_info: %{"type" => "movie"}
      })

    second =
      import_candidate_with_id!("00000000-0000-4000-8000-000000000002", %{
        library_path_id: library_path.id,
        relative_path: "atomic-second.mkv",
        anchor_key: first.anchor_key,
        size: 1_000_000_000,
        discovered_at: DateTime.utc_now() |> DateTime.truncate(:second),
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

  @tag :tmp_dir
  test "a failed promotion for a new provider leaves no metadata, event, or NFO", %{
    tmp_dir: tmp_dir
  } do
    library_path =
      library_path_fixture(%{type: "mixed", path: tmp_dir, write_nfo: true})

    first_path = "Unknown Show/Season 01/Unknown.Show.S01E01.mkv"
    second_path = "Unknown Show/Unknown.Show.Movie.mkv"
    File.mkdir_p!(Path.dirname(Path.join(tmp_dir, first_path)))
    File.write!(Path.join(tmp_dir, first_path), "episode")
    File.write!(Path.join(tmp_dir, second_path), "movie")

    first =
      import_candidate_with_id!("00000000-0000-4000-8000-000000000011", %{
        library_path_id: library_path.id,
        relative_path: first_path,
        anchor_key: "unknown show",
        size: 7,
        discovered_at: DateTime.utc_now() |> DateTime.truncate(:second),
        media_type: "tv_show",
        parsed_info: %{"type" => "tv_show", "season" => 1, "episodes" => [1]}
      })

    second =
      import_candidate_with_id!("00000000-0000-4000-8000-000000000012", %{
        library_path_id: library_path.id,
        relative_path: second_path,
        anchor_key: first.anchor_key,
        size: 5,
        discovered_at: first.discovered_at,
        media_type: "movie",
        parsed_info: %{"type" => "movie"}
      })

    match = %{
      provider_id: Integer.to_string(Mydia.MetadataStubProvider.series_tvdb_id()),
      provider_type: :tvdb,
      title: Mydia.MetadataStubProvider.series_title(),
      match_confidence: 1.0,
      parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
    }

    assert {:error, {:incompatible_media_type, "movie", "tv_show"}} =
             CandidatePromotion.promote_group([first, second], match, config: stub_config())

    assert Repo.aggregate(MediaItem, :count) == 0
    assert Repo.aggregate(Episode, :count) == 0
    assert Repo.aggregate(Event, :count) == 0
    refute File.exists?(Path.join(tmp_dir, "Unknown Show/tvshow.nfo"))
    assert Repo.get(ImportCandidate, first.id)
    assert Repo.get(ImportCandidate, second.id)
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

  test "separate database connections serialize competing promotions at ownership" do
    %{library_path: library_path, movie: movie, candidate: candidate} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        library_path = library_path_fixture(%{type: "movies"})
        movie = media_item_fixture(%{type: "movie", tmdb_id: 60_311})

        candidate =
          import_candidate_fixture(%{
            library_path_id: library_path.id,
            media_type: "movie",
            parsed_info: %{"type" => "movie"}
          })

        %{library_path: library_path, movie: movie, candidate: candidate}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from file in MediaFile, where: file.library_path_id == ^library_path.id)
        Repo.delete_all(from candidate in ImportCandidate, where: candidate.id == ^candidate.id)
        # media_item_fixture/1 above ran on this same real (sandbox: false)
        # connection, so its media_item.added event -- like the media item
        # itself -- was a genuine commit, not something the ordinary
        # per-test sandbox rollback would ever undo. Without this, every run
        # of this test leaks one Event row into the shared, session-persistent
        # SQLite test database, permanently.
        Repo.delete_all(from event in Event, where: event.resource_id == ^movie.id)
        Repo.delete(movie)
        Repo.delete(library_path)
      end)
    end)

    parent = self()
    ref = make_ref()

    promote = fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      send(parent, {:connection_ready, self()})

      try do
        receive do
          {:start_promotion, ^ref} ->
            CandidatePromotion.promote_group([candidate], movie_match(movie),
              config: stub_config(),
              ownership_attempt: fn -> send(parent, {:ownership_attempt, self()}) end,
              ownership_boundary: fn ->
                send(parent, {:ownership_boundary, self()})

                receive do
                  {:release_ownership, ^ref} -> :ok
                end
              end
            )
        end
      after
        Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      end
    end

    first = Task.async(promote)
    second = Task.async(promote)

    assert_receive {:connection_ready, first_pid}, 1_000
    assert_receive {:connection_ready, second_pid}, 1_000
    refute first_pid == second_pid

    send(first.pid, {:start_promotion, ref})
    assert_receive {:ownership_attempt, ^first_pid}, 1_000
    assert_receive {:ownership_boundary, ^first_pid}, 1_000

    # The first task holds SQLite's write lock. The second has reached the
    # ownership boundary but cannot enter its write transaction yet.
    send(second.pid, {:start_promotion, ref})
    assert_receive {:ownership_attempt, ^second_pid}, 1_000
    assert Task.yield(second, 0) == nil

    send(first.pid, {:release_ownership, ref})
    assert {:ok, [_]} = Task.await(first, 2_000)

    assert_receive {:ownership_boundary, ^second_pid}, 1_000
    send(second.pid, {:release_ownership, ref})
    assert {:error, {:candidate_missing, _}} = Task.await(second, 2_000)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(file in MediaFile, where: file.library_path_id == ^library_path.id),
               :count
             ) == 1

      refute Repo.get(ImportCandidate, candidate.id)
    end)
  end
end
