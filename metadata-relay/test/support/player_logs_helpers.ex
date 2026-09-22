defmodule MetadataRelay.PlayerLogsHelpers do
  @moduledoc """
  Builders shared by the player log tests.
  """

  alias MetadataRelay.PlayerLogs.{Batch, Meta, Record}

  @device_id "6f1c2a4e-9b3d-4c1e-8a2f-0d5e7b9c1a3f"

  # 2026-09-22 14:03:12.345 UTC.
  @t 1_790_085_792_345

  def device_id, do: @device_id

  def meta_map(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "meta",
        "kind" => "stream",
        "device_id" => @device_id,
        "device_name" => "Work MacBook",
        "platform" => "macos",
        "os_version" => "macOS 15.6",
        "app_version" => "0.15.0",
        "build" => "150",
        "report" => nil,
        "note" => nil
      },
      overrides
    )
  end

  def record_map(overrides \\ %{}) do
    Map.merge(
      %{
        "t" => @t,
        "l" => "info",
        "tag" => "PlaybackController",
        "msg" => "Opened the stream",
        "sid" => "a3f09c1e",
        "src" => "dart"
      },
      overrides
    )
  end

  @doc "A request body: the given lines (maps are JSON-encoded) as gzipped NDJSON."
  def gz_body(lines) do
    lines
    |> Enum.map_join("\n", fn
      line when is_binary(line) -> line
      map -> Jason.encode!(map)
    end)
    |> Kernel.<>("\n")
    |> :zlib.gzip()
  end

  @doc """
  A decoded batch, as `Ingest.decode/2` would return it.

  Options: `:meta` (keyword overrides for the meta struct), `:records` (a list
  of record maps), `:size` (the decompressed size charged to the quota).
  """
  def batch(opts \\ []) do
    meta =
      struct!(
        Meta,
        Keyword.merge(
          [
            device_id: @device_id,
            kind: "stream",
            device_name: "Work MacBook",
            platform: "macos",
            os_version: "macOS 15.6",
            app_version: "0.15.0",
            build: "150"
          ],
          Keyword.get(opts, :meta, [])
        )
      )

    records =
      opts
      |> Keyword.get(:records, [record_map()])
      |> Enum.map(fn map -> %Record{t: map["t"], sid: map["sid"], line: Jason.encode!(map)} end)

    %Batch{meta: meta, records: records, size: Keyword.get(opts, :size, 1_000), dropped: 0}
  end

  @doc """
  Points `player_logs.dir` at a fresh tmp directory for this test, and puts
  the old config back afterwards. Returns the directory, which does not exist
  until something is written.
  """
  def use_tmp_logs_dir do
    dir = Path.join(System.tmp_dir!(), "player_logs_#{System.unique_integer([:positive])}")
    put_logs_config(:dir, dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc "Overrides one `player_logs` config key for this test."
  def put_logs_config(key, value) do
    previous = Application.fetch_env!(:metadata_relay, :player_logs)
    Application.put_env(:metadata_relay, :player_logs, Keyword.put(previous, key, value))

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:metadata_relay, :player_logs, previous)
    end)

    :ok
  end
end
