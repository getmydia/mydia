defmodule Mydia.Subtitles.ResyncEnqueueTest do
  # async: false and a Bypass stub because this path can reach
  # Downloader.default_config/1, which sets the global :subtitle_relay_url key.
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.SubtitleResync
  alias Mydia.Subtitles.Sidecars

  setup do
    # The app skips Oban in test (engine: false), so Oban.insert cannot be
    # resolved from inside Mydia.Subtitles.ResyncEnqueue.enqueue/2. Start an
    # isolated, manual-mode instance so enqueues land somewhere
    # assert_enqueued/all_enqueued can see them. Same pattern as
    # test/mydia/jobs/segment_detection_test.exs.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    bypass = Bypass.open()
    Application.put_env(:mydia, :subtitle_relay_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:mydia, :subtitle_relay_url) end)
    {:ok, bypass: bypass}
  end

  @tag :tmp_dir
  test "adopting a sidecar enqueues exactly one re-sync job", %{tmp_dir: tmp_dir} do
    media_file = media_file_fixture_in(tmp_dir)
    File.write!(Path.join(tmp_dir, "Movie.en.srt"), sample_srt())

    {:ok, _tally} = Sidecars.reconcile(media_file)

    assert [%{args: %{"media_file_id" => id}}] = all_enqueued(worker: SubtitleResync)
    assert id == media_file.id
  end

  @tag :tmp_dir
  test "a second reconcile of an unchanged directory enqueues nothing new", %{tmp_dir: tmp_dir} do
    media_file = media_file_fixture_in(tmp_dir)
    File.write!(Path.join(tmp_dir, "Movie.en.srt"), sample_srt())

    {:ok, _} = Sidecars.reconcile(media_file)
    {:ok, _} = Sidecars.reconcile(media_file)

    assert length(all_enqueued(worker: SubtitleResync)) == 1
  end

  # Built against the existing library_path_fixture/media_file_fixture pair
  # (test/support/fixtures/settings_fixtures.ex,
  # test/support/fixtures/media_fixtures.ex): a library path rooted at
  # tmp_dir, and a media file inside it whose library_path association is
  # preloaded, since MediaFile.absolute_path/1 (which Sidecars.reconcile/1
  # depends on) requires that association to be loaded.
  defp media_file_fixture_in(tmp_dir) do
    library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: tmp_dir})

    media_file =
      Mydia.MediaFixtures.media_file_fixture(%{
        library_path_id: library_path.id,
        relative_path: "Movie.mkv"
      })

    File.write!(Path.join(tmp_dir, "Movie.mkv"), "not really a video")

    Mydia.Repo.preload(media_file, :library_path)
  end

  defp sample_srt do
    """
    1
    00:00:10,000 --> 00:00:12,000
    Hello there.
    """
  end
end
