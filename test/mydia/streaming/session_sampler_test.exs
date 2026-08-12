defmodule Mydia.Streaming.SessionSamplerTest do
  # async: false is required, not incidental. The sampler is a separate process
  # that queries media files itself, and under the PostgreSQL non-shared sandbox
  # a spawned process cannot see the test's uncommitted rows, so every bitrate
  # lookup returns nil. SQLite is permissive enough to pass either way, which is
  # exactly how this reached CI green locally and red on Postgres.
  use Mydia.DataCase, async: false

  alias Mydia.Streaming.SessionSampler
  alias Mydia.Streaming.SessionSampler.Sample

  describe "estimate_mbps/2" do
    test "direct play uses the file bitrate" do
      assert SessionSampler.estimate_mbps(%{mode: :direct, max_bitrate: nil}, 8_000_000) == 8.0
    end

    test "an uncapped transcode uses the file bitrate" do
      assert SessionSampler.estimate_mbps(%{mode: :transcode, max_bitrate: nil}, 8_000_000) == 8.0
    end

    test "a capped transcode uses the lower of cap and file bitrate" do
      assert SessionSampler.estimate_mbps(%{mode: :transcode, max_bitrate: 4_000_000}, 8_000_000) ==
               4.0
    end

    test "a cap above the source does not inflate the estimate" do
      assert SessionSampler.estimate_mbps(%{mode: :transcode, max_bitrate: 20_000_000}, 8_000_000) ==
               8.0
    end

    test "an unknown bitrate is unmeasurable" do
      assert SessionSampler.estimate_mbps(%{mode: :direct, max_bitrate: nil}, nil) == nil
    end
  end

  describe "ring buffer" do
    test "retains at most the window size, newest last" do
      {:ok, pid} = start_sampler(fn -> [] end, window_size: 3)

      for _ <- 1..5, do: GenServer.call(pid, :tick_now)

      window = SessionSampler.window(pid)

      assert length(window) == 3
      assert Enum.map(window, & &1.at) == Enum.sort(Enum.map(window, & &1.at), DateTime)
    end
  end

  describe "sampling" do
    test "records estimated mbps per session" do
      media_file = measured_media_file(8_000_000)

      sessions = fn ->
        [
          {{:hls_session, media_file.id, "user-1"}, self(),
           %{media_file_id: media_file.id, mode: :direct}}
        ]
      end

      {:ok, pid} = start_sampler(sessions)

      sample = GenServer.call(pid, :tick_now)

      assert %Sample{sessions: %{}} = sample
      assert map_size(sample.sessions) == 1
      assert sample.sessions |> Map.values() |> hd() == 8.0
      assert sample.unmeasured_count == 0
    end

    test "counts sessions whose file has no bitrate as unmeasured" do
      media_file = measured_media_file(nil)

      sessions = fn ->
        [
          {{:hls_session, media_file.id, "user-1"}, self(),
           %{media_file_id: media_file.id, mode: :direct}}
        ]
      end

      {:ok, pid} = start_sampler(sessions)

      sample = GenServer.call(pid, :tick_now)

      assert sample.sessions == %{}
      assert sample.unmeasured_count == 1
    end

    test "skips a registry entry with no media_file_id rather than crashing" do
      sessions = fn -> [{{:hls_session, nil, "user-1"}, self(), %{}}] end

      {:ok, pid} = start_sampler(sessions)

      sample = GenServer.call(pid, :tick_now)

      assert sample.sessions == %{}
      assert sample.unmeasured_count == 0
    end

    test "does not re-query a media file it has already resolved" do
      media_file = measured_media_file(8_000_000)

      sessions = fn ->
        [
          {{:hls_session, media_file.id, "user-1"}, self(),
           %{media_file_id: media_file.id, mode: :direct}}
        ]
      end

      {:ok, pid} = start_sampler(sessions)

      GenServer.call(pid, :tick_now)

      # Deleting the row would make a second lookup return nil, so an unchanged
      # estimate proves the cache served the second tick.
      Mydia.Repo.delete!(media_file)

      sample = GenServer.call(pid, :tick_now)

      assert sample.sessions |> Map.values() |> hd() == 8.0
    end
  end

  describe "resilience" do
    test "window/0 returns an empty list when the sampler is not running" do
      assert SessionSampler.window(:no_such_sampler) == []
    end

    test "current/0 returns an empty sample when the sampler is not running" do
      assert %Sample{sessions: %{}} = SessionSampler.current(:no_such_sampler)
    end
  end

  # estimate_mbps/2 above is exercised against a hand-built map, which bypasses
  # normalize/1. These drive the whole tick path from a realistic registry entry
  # instead, so a normalize/1 that dropped max_bitrate could not pass unnoticed.
  describe "tick path composition" do
    test "a capped transcode stays capped end to end" do
      media_file = measured_media_file(8_000_000)

      sessions = fn ->
        [
          {{:hls_session, media_file.id, "user-1"}, self(),
           %{media_file_id: media_file.id, mode: :transcode, max_bitrate: 4_000_000}}
        ]
      end

      {:ok, pid} = start_sampler(sessions)

      sample = GenServer.call(pid, :tick_now)

      assert sample.sessions |> Map.values() |> hd() == 4.0
    end

    test "an uncapped transcode reports the source rate" do
      media_file = measured_media_file(8_000_000)

      sessions = fn ->
        [
          {{:hls_session, media_file.id, "user-1"}, self(),
           %{media_file_id: media_file.id, mode: :transcode}}
        ]
      end

      {:ok, pid} = start_sampler(sessions)

      sample = GenServer.call(pid, :tick_now)

      assert sample.sessions |> Map.values() |> hd() == 8.0
    end

    test "two sessions on one file get distinct keys so the chart draws two bands" do
      media_file = measured_media_file(6_000_000)

      sessions = fn ->
        [
          {{:hls_session, media_file.id, "user-1"}, self(),
           %{media_file_id: media_file.id, mode: :direct}},
          {{:hls_session, media_file.id, "user-2"}, self(),
           %{media_file_id: media_file.id, mode: :direct}}
        ]
      end

      {:ok, pid} = start_sampler(sessions)

      sample = GenServer.call(pid, :tick_now)

      assert map_size(sample.sessions) == 2
      assert Enum.sum(Map.values(sample.sessions)) == 12.0
    end
  end

  # The dashboard's live chart is driven entirely by this broadcast. Without it
  # the chart silently freezes, which no other test would catch.
  describe "broadcast" do
    test "each tick broadcasts its sample on the dashboard's topic" do
      media_file = measured_media_file(8_000_000)

      sessions = fn ->
        [
          {{:hls_session, media_file.id, "user-1"}, self(),
           %{media_file_id: media_file.id, mode: :direct}}
        ]
      end

      :ok = Phoenix.PubSub.subscribe(Mydia.PubSub, SessionSampler.topic())

      {:ok, pid} = start_sampler(sessions)

      GenServer.call(pid, :tick_now)

      assert_receive {:sample, %Sample{sessions: sessions_map}}, 1_000
      assert sessions_map |> Map.values() |> hd() == 8.0
    end
  end

  defp start_sampler(list_sessions_fun, opts \\ []) do
    opts =
      Keyword.merge(
        [name: nil, tick: false, list_sessions: list_sessions_fun],
        opts
      )

    start_supervised({SessionSampler, opts})
  end

  defp measured_media_file(bitrate) do
    media_item = Mydia.MediaFixtures.media_item_fixture(%{type: "movie"})

    Mydia.MediaFixtures.media_file_fixture(%{
      media_item_id: media_item.id,
      bitrate: bitrate
    })
  end
end
