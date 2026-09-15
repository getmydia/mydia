defmodule Mydia.Downloads.RemovalTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.Jobs.RemoveDownload
  alias Mydia.Repo

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  describe "request_removal/3" do
    test "marks the row pending and enqueues the job" do
      download = download_fixture()

      assert {:ok, %Download{}} =
               Downloads.request_removal(download, "cancel", delete_files: true)

      row = Repo.get!(Download, download.id)
      assert %DateTime{} = row.removal_requested_at
      assert row.removal_kind == "cancel"
      assert row.removal_delete_files
      assert is_nil(row.removal_error)

      assert_enqueued(worker: RemoveDownload, args: %{"download_id" => download.id})
    end

    test "a second request while one is pending writes nothing and enqueues nothing" do
      download = download_fixture()
      {:ok, _} = Downloads.request_removal(download, "cancel")

      assert {:ok, :already_pending} =
               Downloads.request_removal(download, "clear", delete_files: true)

      row = Repo.get!(Download, download.id)
      assert row.removal_kind == "cancel"
      refute row.removal_delete_files
      assert length(all_enqueued(worker: RemoveDownload)) == 1
    end

    test "requesting again after a removal gave up clears the recorded error" do
      download =
        download_fixture(%{removal_kind: "clear", removal_error: "Failed to remove torrent"})

      assert {:ok, %Download{}} = Downloads.request_removal(download, "clear")

      row = Repo.get!(Download, download.id)
      assert %DateTime{} = row.removal_requested_at
      assert is_nil(row.removal_error)
    end

    if Mydia.Repo.__adapter__() == Ecto.Adapters.Postgres do
      alias Ecto.Adapters.SQL.Sandbox

      @barrier_timeout 30_000
      test "concurrent requests keep the first removal intent" do
        # Committed for real so both connections can see it. Inserted bare, not
        # through download_fixture/1: that also commits a media item and its
        # media_item.added event, which on_exit does not delete, and later tests
        # that count media items or events then see them.
        download =
          Sandbox.unboxed_run(Repo, fn ->
            Repo.insert!(%Download{
              title: "Fictional Concurrent Release",
              download_client: "fictional-client",
              download_client_id: "concurrent-#{System.unique_integer([:positive])}"
            })
          end)

        parent = self()
        barrier = make_ref()
        handler_id = "removal-request-lock-#{inspect(barrier)}"

        on_exit(fn ->
          :telemetry.detach(handler_id)

          Sandbox.unboxed_run(Repo, fn ->
            Repo.delete_all(
              from job in Oban.Job, where: job.worker == "Mydia.Jobs.RemoveDownload"
            )

            Repo.delete_all(from row in Download, where: row.id == ^download.id)
          end)
        end)

        :telemetry.attach(
          handler_id,
          [:mydia, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if metadata.source == "downloads" do
              :telemetry.detach(handler_id)
              send(parent, {:first_read, self()})

              receive do
                {:continue, ^barrier} -> :ok
              after
                @barrier_timeout -> raise "the first removal request was never released"
              end
            end
          end,
          nil
        )

        request = fn kind, opts ->
          Task.async(fn ->
            send(parent, {:request_started, self()})
            Sandbox.checkout(Repo, sandbox: false)

            try do
              Downloads.request_removal(download, kind, opts)
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

        first = request.("cancel", [])
        first_pid = first.pid
        assert_receive {:request_started, ^first_pid}, @barrier_timeout
        assert_receive {:first_read, ^first_pid}, @barrier_timeout

        second = request.("clear", delete_files: true)
        second_pid = second.pid
        assert_receive {:request_started, ^second_pid}, @barrier_timeout
        second_early = Task.yield(second, 500)

        send(first_pid, {:continue, barrier})
        first_result = Task.await(first, @barrier_timeout)

        second_result =
          case second_early do
            nil -> Task.await(second, @barrier_timeout)
            {:ok, result} -> result
          end

        assert is_nil(second_early)
        assert {:ok, %Download{removal_kind: "cancel"}} = first_result
        assert {:ok, :already_pending} = second_result

        row = Sandbox.unboxed_run(Repo, fn -> Repo.get!(Download, download.id) end)
        assert row.removal_kind == "cancel"
        refute row.removal_delete_files
      end
    end

    # The job for an earlier request gave up and cleared the pending flag, but
    # it is still incomplete, so Oban's uniqueness would refuse a new job and
    # the row would sit pending with nothing to process it.
    test "refuses a request while the previous job is still incomplete" do
      # Oban's engine is off in test, and uniqueness lives in the engine. Start
      # a real one under the default name, the one Removal inserts through, the
      # same way file_analysis_unique_test.exs does.
      engine =
        case Repo.__adapter__() do
          Ecto.Adapters.Postgres -> Oban.Engines.Basic
          _ -> Oban.Engines.Lite
        end

      start_supervised!(
        {Oban, repo: Repo, engine: engine, testing: :manual, queues: false, plugins: false}
      )

      download =
        download_fixture(%{removal_kind: "cancel", removal_error: "Failed to remove torrent"})

      {:ok, %Oban.Job{conflict?: false}} =
        %{"download_id" => download.id} |> RemoveDownload.new() |> Oban.insert()

      assert {:error, :removal_in_progress} = Downloads.request_removal(download, "cancel")

      row = Repo.get!(Download, download.id)
      assert is_nil(row.removal_requested_at)
      assert row.removal_error == "Failed to remove torrent"
    end

    test "returns :not_found for a row that is already gone" do
      download = download_fixture()
      {:ok, _} = Downloads.delete_download(download)

      assert {:error, :not_found} = Downloads.request_removal(download, "cancel")
      refute_enqueued(worker: RemoveDownload)
    end
  end

  describe "request_reject/2" do
    test "blacklists at once and leaves the replacement search to the job" do
      media_item = media_item_fixture(%{type: "movie"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          indexer: "fictional-indexer",
          metadata: %{"guid" => "fictional-guid-1"}
        })

      assert {:ok, %Download{}} = Downloads.request_reject(download)

      assert Blacklists.blacklisted?("fictional-indexer", "fictional-guid-1")

      row = Repo.get!(Download, download.id)
      assert row.removal_kind == "reject"
      assert row.removal_delete_files
      refute_enqueued(worker: Mydia.Jobs.MovieSearch)
    end

    test "a pending reject leaves existing blacklist state unchanged" do
      {:ok, blacklist} =
        Blacklists.add(
          "fictional-indexer",
          "fictional-guid-pending",
          "Original release",
          "original_reason",
          expires_at: nil
        )

      download =
        download_fixture(%{
          title: "Replacement release",
          indexer: "fictional-indexer",
          metadata: %{"guid" => "fictional-guid-pending"},
          removal_requested_at: now(),
          removal_kind: "cancel"
        })

      assert {:ok, :already_pending} =
               Downloads.request_reject(download,
                 failure_reason: "duplicate_reason",
                 ttl_days: 1
               )

      unchanged = Repo.get!(ReleaseBlacklist, blacklist.id)
      assert unchanged.title == "Original release"
      assert unchanged.failure_reason == "original_reason"
      assert is_nil(unchanged.expires_at)
      assert unchanged.inserted_at == blacklist.inserted_at
      refute_enqueued(worker: RemoveDownload)
    end
  end

  describe "request_clear_all_completed/1" do
    test "requests a clear for each imported row not already pending" do
      imported = download_fixture(%{imported_at: now()})

      already_pending =
        download_fixture(%{
          imported_at: now(),
          removal_requested_at: now(),
          removal_kind: "cancel"
        })

      in_flight = download_fixture()

      assert {:ok, 1} = Downloads.request_clear_all_completed(delete_files: true)

      assert %Download{removal_kind: "clear", removal_delete_files: true} =
               Repo.get!(Download, imported.id)

      assert Repo.get!(Download, already_pending.id).removal_kind == "cancel"
      assert is_nil(Repo.get!(Download, in_flight.id).removal_requested_at)
    end
  end

  describe "count_completed/0" do
    test "does not count imported rows already being removed" do
      download_fixture(%{imported_at: now()})
      download_fixture(%{imported_at: now(), removal_requested_at: now(), removal_kind: "clear"})

      assert Downloads.count_completed() == 1
    end
  end
end
