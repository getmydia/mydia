defmodule Mydia.Library.SegmentDetection.FingerprintCache do
  @moduledoc """
  Persists computed fingerprints so a season is decoded once, not per pairing.

  Storage follows the existing `sprite_blob` / `vtt_blob` / `preview_blob`
  convention: the payload lives in `GeneratedMedia` under the `:fingerprint`
  content type, and `media_files.fingerprint_blob` holds its checksum. One blob
  carries both windows, keyed by segment type.

  ## Why the checksum is read from the row, not the struct

  A season is loaded once and then every file is fingerprinted several times
  over: once as a correlation target, and again each time it is picked as
  someone else's partner. The struct loaded at the start of the run predates
  all of those writes, so trusting its `fingerprint_blob` would miss every
  cache entry the same run just created and cost roughly six decodes per file
  instead of one. Reading through the row also keeps the two windows in one
  blob, since the intro is stored before the credits window is computed.

  Every failure path degrades to a miss. A cache that cannot be read or written
  costs time, never correctness.
  """

  import Ecto.Query

  require Logger

  alias Mydia.Library.GeneratedMedia
  alias Mydia.Library.MediaFile
  alias Mydia.Library.SegmentDetection.Fingerprint
  alias Mydia.Repo

  @doc """
  Returns the cached fingerprint for `type`, or `:miss`.

  `window_start_ms` is not stored, because it is derived from the file's
  runtime rather than from the fingerprint. The caller sets it.
  """
  @spec fetch(MediaFile.t(), String.t()) :: {:ok, Fingerprint.Result.t()} | :miss
  def fetch(%MediaFile{} = file, type) do
    case file |> current_checksum() |> read() do
      %{^type => %{"hashes" => hashes, "frame_ms" => frame_ms}} ->
        {:ok, %Fingerprint.Result{hashes: hashes, frame_ms: frame_ms}}

      _miss ->
        :miss
    end
  end

  @doc """
  Stores the fingerprint for `type`, merging it into whatever is already cached.
  """
  @spec put(MediaFile.t(), String.t(), Fingerprint.Result.t()) :: :ok
  def put(%MediaFile{} = file, type, %Fingerprint.Result{} = result) do
    payload =
      file
      |> current_checksum()
      |> read()
      |> Map.put(type, %{"hashes" => result.hashes, "frame_ms" => result.frame_ms})

    with {:ok, encoded} <- Jason.encode(payload),
         {:ok, stored} <- GeneratedMedia.store(:fingerprint, encoded) do
      Repo.update_all(from(mf in MediaFile, where: mf.id == ^file.id),
        set: [fingerprint_blob: stored]
      )
    else
      {:error, reason} ->
        Logger.debug("Could not cache fingerprint", file_id: file.id, reason: inspect(reason))
    end

    :ok
  end

  defp current_checksum(file) do
    Repo.one(from(mf in MediaFile, where: mf.id == ^file.id, select: mf.fingerprint_blob))
  end

  defp read(nil), do: %{}

  defp read(checksum) do
    with {:ok, binary} <- File.read(GeneratedMedia.get_path(:fingerprint, checksum)),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(binary) do
      decoded
    else
      _unreadable -> %{}
    end
  end
end
