defmodule Mydia.Torrent do
  @moduledoc """
  NIF bindings for the BitTorrent engine based on librqbit.
  """
  use Rustler, otp_app: :mydia, crate: "mydia_torrent"

  @doc """
  Start the torrent engine with a staging directory.
  Returns the resource on success.
  """
  def start_engine(_staging_dir), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Add a torrent from a magnet link.
  Events (metadata ready, etc.) will be sent to the given pid.
  Returns `:ok` if the command was accepted.
  """
  def add_torrent(_resource, _pid, _magnet), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Read a chunk of data from a torrent file.
  Returns `{:ok, data}` or `{:error, reason}`.
  """
  def read_chunk(_resource, _torrent_id, _file_id, _offset, _len),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Cancel a torrent and optionally delete its files.
  """
  def cancel_torrent(_resource, _torrent_id, _delete_files),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Cancel a torrent by its infohash (40-char hex). Used when the torrent never
  completed metadata resolution and we therefore never received a numeric
  torrent_id. Returns `:ok` whether or not the torrent was actually present
  in librqbit's session.
  """
  def cancel_torrent_by_infohash(_resource, _info_hash, _delete_files),
    do: :erlang.nif_error(:nif_not_loaded)
end

defmodule Mydia.Torrent.AddTorrentResponse do
  defstruct [:id, :info_hash, :name]
end

defmodule Mydia.Torrent.MetadataReady do
  defstruct [:torrent_id, :file_id, :file_name, :total_size]
end
