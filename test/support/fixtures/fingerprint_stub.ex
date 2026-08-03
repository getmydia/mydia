defmodule Mydia.FingerprintStub do
  @moduledoc """
  Test double for `Mydia.Library.SegmentDetection.Fingerprint`.

  Streams are registered per file path in an Agent before the code under test
  runs, so a test can construct a season whose episodes share an exact,
  known-length run of audio and then assert on the timestamps that come out.

  The window arguments are deliberately ignored. A test registers one stream
  per path and gets it back for both the intro and the credits window, so a
  test that cares about only one segment type asserts on that type alone.
  """

  @behaviour Mydia.Library.SegmentDetection.Fingerprint

  alias Mydia.Library.SegmentDetection.Fingerprint.Result

  @doc "Starts the registry backing the stub."
  def start_link do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Registers the hash stream returned for `path`, with a frame duration in ms."
  def put(path, hashes, frame_ms \\ 100.0) do
    Agent.update(__MODULE__, &Map.put(&1, path, %Result{hashes: hashes, frame_ms: frame_ms}))
  end

  @doc "Registers an error to be returned for `path`."
  def put_error(path, reason) do
    Agent.update(__MODULE__, &Map.put(&1, path, {:error, reason}))
  end

  @impl true
  def available?, do: true

  @impl true
  def fingerprint(path, _start_s, _length_s) do
    case Agent.get(__MODULE__, &Map.get(&1, path)) do
      nil -> {:error, :not_registered}
      {:error, reason} -> {:error, reason}
      %Result{} = result -> {:ok, result}
    end
  end
end
