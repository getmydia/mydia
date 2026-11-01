defmodule Mydia.Jobs.PathMappingSuggestionBackfillTest do
  # Changes the :path_mapping_roots app env and drives an isolated Oban
  # instance, so it runs serially.
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Jobs.PathMappingSuggestionBackfill

  setup do
    start_supervised!(
      {Oban, repo: Mydia.Repo, engine: Mydia.AdapterHelpers.oban_engine(), testing: :manual}
    )

    tmp = Path.join(System.tmp_dir!(), "pmsb_#{System.unique_integer([:positive])}")
    root = Path.join(tmp, "data")
    File.mkdir_p!(Path.join([root, "complete", "Fictional.Salt.Meridian.S01E01"]))

    previous = Application.get_env(:mydia, :path_mapping_roots)
    Application.put_env(:mydia, :path_mapping_roots, [root])

    on_exit(fn ->
      Application.put_env(:mydia, :path_mapping_roots, previous)
      File.rm_rf(tmp)
    end)

    {:ok, root: root}
  end

  defp mismatch(reported_path, attrs \\ %{}) do
    media_item = media_item_fixture()

    download_fixture(
      Map.merge(
        %{
          media_item_id: media_item.id,
          status: "completed",
          import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          import_failure_reason: "path_mapping_mismatch",
          import_reported_path: reported_path
        },
        attrs
      )
    )
  end

  test "fills a suggestion for an unsearched mismatch", %{root: root} do
    d = mismatch("/downloads/complete/Fictional.Salt.Meridian.S01E01")

    assert :ok = perform_job(PathMappingSuggestionBackfill, %{})

    updated = Downloads.get_download!(d.id)
    assert updated.path_mapping_remote_prefix == "/downloads/complete"
    assert updated.path_mapping_local_prefix == Path.join(root, "complete")
    assert %DateTime{} = updated.path_mapping_searched_at
  end

  test "stamps a mismatch with no match so it is never searched again" do
    d = mismatch("/downloads/complete/Fictional.Copper.Lantern.S02E03")

    assert :ok = perform_job(PathMappingSuggestionBackfill, %{})

    updated = Downloads.get_download!(d.id)
    assert updated.path_mapping_remote_prefix == nil
    assert %DateTime{} = updated.path_mapping_searched_at
    assert PathMappingSuggestionBackfill.pending_ids(10) == []
  end

  test "skips rows already searched and rows that are not mismatches" do
    searched_at = ~U[2026-01-01 00:00:00Z]

    searched =
      mismatch("/downloads/complete/Fictional.Salt.Meridian.S01E01", %{
        path_mapping_searched_at: searched_at
      })

    other =
      mismatch("/downloads/complete/Fictional.Salt.Meridian.S01E01", %{
        import_failure_reason: "no_files"
      })

    assert PathMappingSuggestionBackfill.pending_ids(10) == []
    assert :ok = perform_job(PathMappingSuggestionBackfill, %{})

    assert Downloads.get_download!(searched.id).path_mapping_searched_at == searched_at
    assert Downloads.get_download!(other.id).path_mapping_searched_at == nil
  end

  test "reschedules itself while a batch did work, and stops when drained" do
    mismatch("/downloads/complete/Fictional.Salt.Meridian.S01E01")

    assert :ok = perform_job(PathMappingSuggestionBackfill, %{})
    assert_enqueued(worker: PathMappingSuggestionBackfill)

    Oban.drain_queue(queue: :maintenance)
    assert PathMappingSuggestionBackfill.pending_ids(10) == []
  end

  test "enqueue_once/0 does not stack a second job" do
    assert :ok = PathMappingSuggestionBackfill.enqueue_once()
    assert :ok = PathMappingSuggestionBackfill.enqueue_once()

    assert [_one] = all_enqueued(worker: PathMappingSuggestionBackfill)
  end
end
