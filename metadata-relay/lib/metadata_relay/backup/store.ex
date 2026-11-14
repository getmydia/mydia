defmodule MetadataRelay.Backup.Store do
  @moduledoc """
  The encrypted slot files under `backup.dir`.

  Paths handed in and out are relative to that directory. Vault and slot ids
  are validated as lowercase hex and `seq` as an integer before they become a
  path segment, so none can climb out of it. Bodies are already compressed
  ciphertext, so nothing is gzipped here.

  A file is written to `<name>.tmp` and renamed into place, so a reader never
  sees half of one.
  """

  @hex ~r/\A[0-9a-f]+\z/

  @spec root() :: Path.t()
  def root, do: Application.fetch_env!(:metadata_relay, :backup) |> Keyword.fetch!(:dir)

  @spec slot_path(String.t(), String.t(), integer()) :: Path.t()
  def slot_path(vault_id, slot_id, seq) when is_integer(seq) do
    validate_hex!(vault_id)
    validate_hex!(slot_id)
    Path.join(vault_id, "#{slot_id}-#{seq}.bin")
  end

  def slot_path(_vault_id, _slot_id, seq),
    do: raise(ArgumentError, "seq must be an integer, got: #{inspect(seq)}")

  @spec write(Path.t(), binary()) :: :ok | {:error, term()}
  def write(relative, binary) do
    final = absolute(relative)
    tmp = final <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(final)),
         :ok <- File.write(tmp, binary),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @spec read(Path.t()) :: {:ok, binary()} | {:error, :enoent}
  def read(relative) do
    case File.read(absolute(relative)) do
      {:ok, bin} -> {:ok, bin}
      {:error, _} -> {:error, :enoent}
    end
  end

  @spec delete(Path.t()) :: :ok
  def delete(relative) do
    _ = File.rm(absolute(relative))
    :ok
  end

  @spec delete_vault_dir(String.t()) :: :ok
  def delete_vault_dir(vault_id) do
    validate_hex!(vault_id)
    _ = File.rm_rf(Path.join(root(), vault_id))
    :ok
  end

  defp absolute(relative), do: Path.join(root(), relative)

  defp validate_hex!(id) when is_binary(id) do
    if Regex.match?(@hex, id),
      do: :ok,
      else: raise(ArgumentError, "expected lowercase hex id, got: #{inspect(id)}")
  end

  defp validate_hex!(id),
    do: raise(ArgumentError, "expected lowercase hex id, got: #{inspect(id)}")
end
