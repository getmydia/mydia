defmodule Mydia.Library.CandidatePromotionS3Test do
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.MediaFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Library.{CandidatePromotion, ImportCandidate, MediaFile}
  alias Mydia.Repo
  alias Mydia.Settings

  @rel "Invented Film (2031)/film.mkv"

  setup do
    bypass = Bypass.open()

    {:ok, _} =
      Settings.create_storage_backend(%{
        name: "m",
        endpoint: "http://localhost:#{bypass.port}",
        region: "us-east-1",
        bucket: "lib",
        access_key_id: "k",
        secret_access_key: "s"
      })

    {:ok, lp} =
      Settings.create_library_path(%{path: "s3://m/movies", type: "movies", monitored: true})

    candidate = import_candidate_fixture(library_path_id: lp.id, relative_path: @rel, size: 4)
    movie = media_item_fixture(%{type: "movie", title: "Invented Film", year: 2031})

    %{bypass: bypass, lp: lp, candidate: candidate, movie: movie}
  end

  # Answers the HEAD for the candidate's object. Attaching also reconciles
  # sidecar subtitles, which lists the item folder; the bucket is empty.
  defp head_object(bypass, status, on_head \\ fn -> :ok end) do
    Bypass.expect(bypass, fn
      %{method: "HEAD"} = conn ->
        assert URI.decode(conn.request_path) == "/lib/movies/#{@rel}"
        on_head.()

        conn
        |> Plug.Conn.put_resp_header("last-modified", "Wed, 01 Oct 2031 10:00:00 GMT")
        |> Plug.Conn.resp(status, "data")

      %{method: "GET"} = conn ->
        Plug.Conn.resp(
          conn,
          200,
          "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
        )
    end)
  end

  test "attaches a candidate whose object exists", ctx do
    head_object(ctx.bypass, 200)

    assert {:ok, %MediaFile{} = file} = CandidatePromotion.attach(ctx.candidate, ctx.movie, [])
    assert file.relative_path == @rel
    refute Repo.get(ImportCandidate, ctx.candidate.id)
  end

  test "the object is checked before the transaction opens", ctx do
    test_pid = self()

    head_object(ctx.bypass, 200, fn -> send(test_pid, :head) end)

    assert {:ok, %MediaFile{}} =
             CandidatePromotion.attach(ctx.candidate, ctx.movie,
               ownership_boundary: fn -> send(test_pid, :in_transaction) end
             )

    {:messages, messages} = Process.info(self(), :messages)

    assert Enum.find_index(messages, &(&1 == :head)) <
             Enum.find_index(messages, &(&1 == :in_transaction))
  end

  test "a missing object is :file_missing and drops the candidate", ctx do
    head_object(ctx.bypass, 404)

    assert {:error, :file_missing} = CandidatePromotion.attach(ctx.candidate, ctx.movie, [])
    refute Repo.get(ImportCandidate, ctx.candidate.id)
  end

  test "an unreachable backend keeps the candidate", ctx do
    Bypass.down(ctx.bypass)

    assert {:error, {:storage, %Mydia.Storage.Error{kind: :unreachable}}} =
             CandidatePromotion.attach(ctx.candidate, ctx.movie, [])

    assert Repo.get(ImportCandidate, ctx.candidate.id)
  end

  test "a deleted storage backend keeps the candidate", ctx do
    Repo.delete_all(Mydia.Settings.StorageBackend)

    assert {:error, {:storage, %Mydia.Storage.Error{kind: :misconfigured}}} =
             CandidatePromotion.attach(ctx.candidate, ctx.movie, [])

    assert Repo.get(ImportCandidate, ctx.candidate.id)
  end

  test "a queued delete on an unreachable S3 candidate is recorded as failed", ctx do
    {1, _} =
      Repo.update_all(from(c in ImportCandidate, where: c.id == ^ctx.candidate.id),
        set: [queued_op: "delete"]
      )

    # Nothing answers on the endpoint: the delete cannot be told from an outage.
    Bypass.down(ctx.bypass)

    assert {:ok, %{deleted: 0, failed: 1}} = ImportCandidates.drain_delete(ctx.lp.id)

    stored = Repo.get!(ImportCandidate, ctx.candidate.id)
    assert is_nil(stored.queued_op)
    assert stored.queue_error =~ "cannot reach storage"
  end
end
