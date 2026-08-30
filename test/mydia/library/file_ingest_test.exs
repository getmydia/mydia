defmodule Mydia.Library.FileIngestTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.{FileIngest, ImportCandidate, MediaFile}
  alias Mydia.Repo

  defp match(movie, confidence) do
    %{
      provider_id: Integer.to_string(movie.tmdb_id),
      provider_type: :tmdb,
      title: movie.title,
      year: movie.year,
      match_confidence: confidence,
      parsed_info: %{type: :movie, season: nil, episodes: []}
    }
  end

  defp candidate do
    library_path = library_path_fixture(%{type: "movies"})

    import_candidate_fixture(%{
      library_path_id: library_path.id,
      media_type: "movie",
      parsed_info: %{"type" => "movie"}
    })
  end

  test "review mode retains an otherwise promotable candidate" do
    candidate = candidate()
    movie = media_item_fixture(%{type: "movie", tmdb_id: 60_301})

    assert {:candidate, %ImportCandidate{id: id}} =
             FileIngest.ingest(candidate, match(movie, 1.0), policy: :review)

    assert id == candidate.id
    assert Repo.get(ImportCandidate, candidate.id).confidence == 1.0
    refute Repo.exists?(MediaFile)
  end

  test "unattended mode promotes at the 0.85 boundary" do
    candidate = candidate()
    movie = media_item_fixture(%{type: "movie", tmdb_id: 60_302})

    assert {:promoted, [%MediaFile{media_item_id: media_item_id}]} =
             FileIngest.ingest(candidate, match(movie, 0.85), policy: :unattended)

    assert media_item_id == movie.id
    refute Repo.get(ImportCandidate, candidate.id)
  end

  test "unattended mode retains a candidate below the threshold" do
    candidate = candidate()
    movie = media_item_fixture(%{type: "movie", tmdb_id: 60_303})

    assert {:candidate, %ImportCandidate{id: id}} =
             FileIngest.ingest(candidate, match(movie, 0.849), policy: :unattended)

    assert id == candidate.id
    assert Repo.get(ImportCandidate, candidate.id).provider_id == Integer.to_string(movie.tmdb_id)
    refute Repo.exists?(MediaFile)
  end

  test "a nil match records retry backoff on the same candidate" do
    candidate = candidate()

    assert :no_match = FileIngest.ingest(candidate, nil, policy: :unattended)

    reloaded = Repo.get!(ImportCandidate, candidate.id)
    assert reloaded.attempts == 1
    assert reloaded.last_error == "no_match"
    assert DateTime.compare(reloaded.next_retry_at, DateTime.utc_now()) == :gt
  end

  test "review mode stores parsed information in the durable candidate" do
    candidate = candidate()
    movie = media_item_fixture(%{type: "movie", tmdb_id: 60_304})

    tv_match = %{
      match(movie, 0.4)
      | parsed_info: %{type: :tv_show, season: 2, episodes: [5, 6]}
    }

    assert {:candidate, _} = FileIngest.ingest(candidate, tv_match, policy: :review)

    assert %ImportCandidate{parsed_info: parsed_info} = Repo.get!(ImportCandidate, candidate.id)
    assert parsed_info["type"] == "tv_show"
    assert parsed_info["season"] == 2
    assert parsed_info["episodes"] == [5, 6]
  end

  test "a deleted candidate is not recreated when promotion loses the row" do
    candidate = candidate()
    movie = media_item_fixture(%{type: "movie", tmdb_id: 60_308})
    assert {:ok, _} = Repo.delete(candidate)

    candidate_id = candidate.id

    assert {:error, {:candidate_missing, ^candidate_id}} =
             FileIngest.ingest(candidate, match(movie, 1.0), policy: :unattended)

    refute Repo.get(ImportCandidate, candidate.id)
    refute Mydia.ImportCandidates.get_by_path(candidate.library_path_id, candidate.relative_path)
  end

  test "a losing promotion failure cannot resurrect the winner's deleted candidate" do
    %{library_path: library_path, movie: movie, candidate: candidate} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        library_path = library_path_fixture(%{type: "movies"})
        movie = media_item_fixture(%{type: "movie", tmdb_id: 60_312})

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
        Repo.delete_all(from stored in ImportCandidate, where: stored.id == ^candidate.id)
        Repo.delete(movie)
        Repo.delete(library_path)
      end)
    end)

    parent = self()
    ref = make_ref()

    ingest = fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      send(parent, {:ingest_connection_ready, self()})

      try do
        receive do
          {:start_ingest, ^ref} ->
            FileIngest.ingest(candidate, match(movie, 1.0),
              policy: :unattended,
              ownership_attempt: fn -> send(parent, {:ingest_ownership_attempt, self()}) end,
              ownership_boundary: fn ->
                send(parent, {:ingest_ownership_boundary, self()})

                receive do
                  {:release_ingest_ownership, ^ref} -> :ok
                end
              end
            )
        end
      after
        Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      end
    end

    winner = Task.async(ingest)
    loser = Task.async(ingest)

    assert_receive {:ingest_connection_ready, winner_pid}, 1_000
    assert_receive {:ingest_connection_ready, loser_pid}, 1_000

    send(winner.pid, {:start_ingest, ref})
    assert_receive {:ingest_ownership_boundary, ^winner_pid}, 1_000

    # The losing FileIngest reaches promotion while the winner owns the SQLite
    # write lock, so it records its failure only after the winner deletes.
    send(loser.pid, {:start_ingest, ref})
    assert_receive {:ingest_ownership_attempt, ^loser_pid}, 1_000
    assert Task.yield(loser, 0) == nil

    send(winner.pid, {:release_ingest_ownership, ref})
    assert {:promoted, [_]} = Task.await(winner, 2_000)

    assert_receive {:ingest_ownership_boundary, ^loser_pid}, 1_000
    send(loser.pid, {:release_ingest_ownership, ref})
    assert {:error, {:candidate_missing, candidate_id}} = Task.await(loser, 2_000)
    assert candidate_id == candidate.id

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      refute Repo.get(ImportCandidate, candidate.id)

      refute Mydia.ImportCandidates.get_by_path(
               candidate.library_path_id,
               candidate.relative_path
             )
    end)
  end

  test "an unrecognized provider type is retryable and cannot promote" do
    candidate = candidate()

    invalid_match = %{
      match(media_item_fixture(%{type: "movie", tmdb_id: 60_309}), 1.0)
      | provider_type: :other
    }

    assert {:error, {:invalid_match_result, _}} =
             FileIngest.ingest(candidate, invalid_match, policy: :unattended)

    assert %ImportCandidate{attempts: 1, next_retry_at: next_retry_at} =
             Repo.get!(ImportCandidate, candidate.id)

    assert next_retry_at
    refute Repo.exists?(MediaFile)
  end

  test "a malformed provider ID is retryable rather than raising" do
    candidate = candidate()

    malformed_match = %{
      match(media_item_fixture(%{type: "movie", tmdb_id: 60_310}), 1.0)
      | provider_id: "not-an-id"
    }

    assert {:error, {:invalid_provider_id, "not-an-id"}} =
             FileIngest.ingest(candidate, malformed_match, policy: :unattended)

    assert %ImportCandidate{attempts: 1} = Repo.get!(ImportCandidate, candidate.id)
    refute Repo.exists?(MediaFile)
  end
end
