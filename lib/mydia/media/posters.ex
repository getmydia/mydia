defmodule Mydia.Media.Posters do
  @moduledoc """
  Resolves which poster a media item displays.

  A user-chosen `poster_override` (a hosted `/generated/posters/...` path or a
  provider path) wins over the provider's `metadata.poster_path`.
  """

  alias Mydia.Accounts.Scope
  alias Mydia.Media.{ItemWrites, MediaItem, PosterStore}
  alias Mydia.Media.Posters.Candidate
  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Repo
  alias Mydia.Storage
  alias Mydia.Storage.Location

  @image_extensions ~w(.jpg .jpeg .png .webp)
  @preferred_names ~w(poster folder cover)
  @max_candidate_bytes 10_000_000
  @season_dir ~r/^(season|series|specials|s\d+)/i

  @doc """
  Returns the effective poster path for a media item, or nil.

  Reads `poster_override` first, then the metadata poster path. Empty strings
  count as unset.
  """
  @spec effective_path(Mydia.Media.MediaItem.t() | map()) :: String.t() | nil
  def effective_path(item) do
    present(Map.get(item, :poster_override)) ||
      present(MetadataAccess.get_field(item, :poster_path))
  end

  @doc "Chooses a provider poster path (e.g. `/abc.jpg`) as the override."
  @spec set_provider_poster(Scope.t(), MediaItem.t(), String.t()) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def set_provider_poster(%Scope{} = scope, %MediaItem{} = item, path) when is_binary(path) do
    with :ok <- authorize(scope, item),
         :ok <- reject_hosted(path) do
      persist(scope, item, path)
    end
  end

  @doc "Stores uploaded image bytes as the override."
  @spec set_uploaded_poster(Scope.t(), MediaItem.t(), binary()) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def set_uploaded_poster(%Scope{} = scope, %MediaItem{} = item, binary) when is_binary(binary) do
    with :ok <- authorize(scope, item),
         {:ok, url} <- PosterStore.write(item.id, binary) do
      scope |> persist(item, url) |> cleanup_on_error(item, url)
    end
  end

  # Identical bytes map to the same file name, which the item may already be
  # using, so only a fresh file is cleaned up.
  defp cleanup_on_error({:ok, _} = ok, _item, _url), do: ok

  defp cleanup_on_error(error, item, url) do
    if url != item.poster_override, do: PosterStore.delete(url)
    error
  end

  @doc """
  Image files (`.jpg .jpeg .png .webp`) sitting directly in the folder(s) of a
  media item's files, across local and S3 libraries.

  A movie's folder is its file's directory. A show's is its episode file's
  directory, one level up when that directory is a season folder. Files in the
  library root are not listed, since they belong to no single item. Local
  symlinks are dropped. `poster.*`, `folder.*` and `cover.*` come first.
  """
  @spec list_library_poster_candidates(MediaItem.t()) :: [Candidate.t()]
  def list_library_poster_candidates(%MediaItem{} = item) do
    item
    |> candidate_folders()
    |> Enum.flat_map(&list_folder/1)
    |> Enum.uniq_by(&{&1.library_path_id, &1.relative_path})
    |> Enum.sort_by(&sort_key/1)
  end

  @doc """
  Reads a listed candidate's bytes. Only an exact member of
  `list_library_poster_candidates/1` is readable; anything else (traversal,
  absolute paths, symlinks, non-images) is `{:error, :not_found}`.
  """
  @spec read_candidate(MediaItem.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, :not_found | :too_large}
  def read_candidate(%MediaItem{} = item, library_path_id, relative_path) do
    with %Candidate{} = candidate <- find_candidate(item, library_path_id, relative_path),
         :ok <- check_size(candidate),
         {:ok, bytes} <- read_bytes(candidate) do
      {:ok, bytes}
    else
      nil -> {:error, :not_found}
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :not_found}
    end
  end

  @doc "Copies a listed image file into the poster store and sets it as the override."
  @spec set_poster_from_library_file(Scope.t(), MediaItem.t(), String.t(), String.t()) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def set_poster_from_library_file(%Scope{} = scope, %MediaItem{} = item, lp_id, relative_path) do
    with {:ok, bytes} <- read_candidate(item, lp_id, relative_path) do
      set_uploaded_poster(scope, item, bytes)
    end
  end

  @doc "Clears the override so the provider's poster shows again."
  @spec reset_poster(Scope.t(), MediaItem.t()) :: {:ok, MediaItem.t()} | {:error, term()}
  def reset_poster(%Scope{} = scope, %MediaItem{} = item) do
    with :ok <- authorize(scope, item) do
      persist(scope, item, nil)
    end
  end

  defp find_candidate(item, library_path_id, relative_path) do
    item
    |> list_library_poster_candidates()
    |> Enum.find(&(&1.library_path_id == library_path_id and &1.relative_path == relative_path))
  end

  defp check_size(%Candidate{size: size}) when size > @max_candidate_bytes,
    do: {:error, :too_large}

  defp check_size(_), do: :ok

  defp read_bytes(%Candidate{size: size} = candidate) do
    lp = Repo.get(Mydia.Settings.LibraryPath, candidate.library_path_id)

    with %{} <- lp,
         {:ok, loc} <- Storage.location(lp),
         {:ok, source} <- Storage.source(loc, candidate.relative_path) do
      Storage.read_range(source, 0, size)
    else
      _ -> {:error, :not_found}
    end
  end

  # {library_path, directory} pairs, deduplicated, never the library root.
  defp candidate_folders(%MediaItem{} = item) do
    item = Repo.preload(item, media_files: :library_path, episodes: [media_files: :library_path])

    {files, adjust} =
      if item.type == "tv_show",
        do: {Enum.flat_map(item.episodes, & &1.media_files), &show_dir/1},
        else: {item.media_files, & &1}

    files
    |> Enum.flat_map(fn
      %{library_path: %{} = lp, relative_path: rel} when is_binary(rel) ->
        [{lp, rel |> Path.dirname() |> adjust.()}]

      _ ->
        []
    end)
    |> Enum.reject(fn {_lp, dir} -> dir in [".", ""] end)
    |> Enum.uniq_by(fn {lp, dir} -> {lp.id, dir} end)
  end

  defp show_dir(dir) do
    if Regex.match?(@season_dir, Path.basename(dir)), do: Path.dirname(dir), else: dir
  end

  defp list_folder({lp, dir}) do
    with {:ok, loc} <- Storage.location(lp),
         child = Location.child(loc, dir),
         {:ok, entries} <- Storage.list(child) do
      for entry <- entries,
          name = entry.relative_path,
          not String.contains?(name, "/"),
          entry.size > 0,
          String.downcase(Path.extname(name)) in @image_extensions,
          not symlink?(child, name) do
        %Candidate{
          library_path_id: lp.id,
          relative_path: Path.join(dir, name),
          name: name,
          size: entry.size
        }
      end
    else
      _ -> []
    end
  end

  defp symlink?(%Location{kind: :local, root: root}, name),
    do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(Path.join(root, name)))

  defp symlink?(_, _), do: false

  defp sort_key(%Candidate{name: name}) do
    base = name |> Path.rootname() |> String.downcase()
    rank = Enum.find_index(@preferred_names, &(&1 == base)) || length(@preferred_names)
    {rank, String.downcase(name)}
  end

  # A provider path must never name a hosted file: that would let one item
  # point at, and later delete, another item's upload.
  defp reject_hosted(path),
    do: if(PosterStore.hosted?(path), do: {:error, :invalid_poster}, else: :ok)

  defp authorize(scope, item),
    do: ItemWrites.authorize_write(scope, ItemWrites.merged_write_attrs(item, %{}))

  defp persist(scope, %MediaItem{poster_override: previous} = item, value) do
    changeset = MediaItem.poster_override_changeset(item, %{poster_override: value})

    # An event with an actor type needs an actor id, so a scope without a
    # user is recorded as the system.
    actor =
      case scope.user do
        %{id: id} -> [actor_type: :user, actor_id: id]
        _ -> [actor_type: :system]
      end

    opts = [{:reason, "Poster changed"} | actor]

    with {:ok, updated} <- ItemWrites.persist_and_audit_media_item(changeset, item, opts) do
      if previous != value, do: PosterStore.delete(previous)
      {:ok, updated}
    end
  end

  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
  defp present(_), do: nil
end
