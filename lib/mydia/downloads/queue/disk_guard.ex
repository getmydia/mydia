defmodule Mydia.Downloads.Queue.DiskGuard do
  @moduledoc """
  Refuses a grab the built-in client's download volume cannot hold, keeping
  `min_free_space_bytes` free. Anything unmeasurable passes: another client,
  no reserve, an unknown size, or a volume whose free space cannot be read.

  Run by `Queue.ClientSelection` just before the add.
  """

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.DiskSpace
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.WantedFiles
  alias Mydia.Indexers.SearchResult

  require Logger

  # The disk reserve is set in decimal gigabytes (`min_free_space_gb`).
  @gb 1_000_000_000

  @doc """
  `:ok`, or `{:error, {:client_error, %Client.Error{type: :insufficient_space}}}`
  when the bytes the add would download (the selection's, else the release
  size) plus the reserve exceed the free space. `client_config` is the map form
  (`ClientSelection.config_to_map/1`). `opts[:free_bytes]` replaces
  `DiskSpace.free_bytes/1` in tests.
  """
  @spec check(map(), WantedFiles.t() | nil, SearchResult.t(), keyword()) ::
          :ok | {:error, {:client_error, Client.Error.t()}}
  def check(client_config, selection, search_result, opts) do
    with true <- BuiltIn.managed?(client_config),
         %{config: %{download_path: path, min_free_space_bytes: reserve}} when reserve > 0 <-
           BuiltIn.runtime(),
         needed when is_integer(needed) <- space_needed(selection, search_result) do
      free_fun = Keyword.get(opts, :free_bytes, &DiskSpace.free_bytes/1)

      case free_fun.(path) do
        {:ok, free} when needed + reserve > free ->
          {:error, {:client_error, insufficient_space_error(needed, free, reserve)}}

        {:ok, _free} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not measure free space; skipping the disk guard",
            path: path,
            reason: inspect(reason)
          )

          :ok
      end
    else
      _ -> :ok
    end
  end

  defp space_needed(%WantedFiles{selected_bytes: bytes}, _search_result), do: bytes

  defp space_needed(nil, %SearchResult{size: size}) when is_integer(size) and size > 0, do: size
  defp space_needed(_selection, _search_result), do: nil

  defp insufficient_space_error(needed, free, reserve) do
    message =
      "Not enough space on the download volume: needs #{DiskSpace.format_gb(needed)}, " <>
        "#{DiskSpace.format_gb(free)} free, #{div(reserve, @gb)} GB kept free"

    Client.Error.insufficient_space(message, %{needed: needed, free: free, reserve: reserve})
  end
end
