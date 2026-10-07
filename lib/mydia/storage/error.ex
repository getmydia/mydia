defmodule Mydia.Storage.Error do
  @moduledoc "Error returned by every `Mydia.Storage` call. `message` never contains secrets."

  # `:misconfigured` is a setup problem (unknown backend, malformed storage
  # path or endpoint). It says nothing about whether a file exists, so callers
  # treat it like an outage, never as "missing". `:exists` is a refused
  # exclusive create.
  @kinds [:not_found, :forbidden, :unreachable, :provider, :read_only, :misconfigured, :exists]

  @type kind ::
          :not_found
          | :forbidden
          | :unreachable
          | :provider
          | :read_only
          | :misconfigured
          | :exists
  @type t :: %__MODULE__{kind: kind(), message: String.t()}

  defexception [:kind, :message]

  @spec new(kind(), String.t()) :: t()
  def new(kind, message) when kind in @kinds and is_binary(message),
    do: %__MODULE__{kind: kind, message: message}

  @doc "Maps a POSIX reason from `File` to an error."
  @spec from_posix(atom(), String.t()) :: t()
  def from_posix(:enoent, path), do: new(:not_found, "not found: #{path}")
  def from_posix(:enotdir, path), do: new(:not_found, "not a directory: #{path}")
  def from_posix(:eacces, path), do: new(:forbidden, "permission denied: #{path}")
  def from_posix(:eexist, path), do: new(:exists, "already exists: #{path}")
  def from_posix(:erofs, path), do: new(:forbidden, "read-only file system: #{path}")
  def from_posix(reason, path), do: new(:provider, "#{reason}: #{path}")
end
