defmodule Mydia.ImportCandidates do
  @moduledoc "Persistence operations for durable import candidates."

  import Ecto.Query

  alias Mydia.Library.{ImportCandidate, PathAnchor}
  alias Mydia.Media.Episode
  alias Mydia.Repo

  @spec upsert(map() | keyword()) :: {:ok, ImportCandidate.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    attrs = Map.new(attrs)
    library_path_id = Map.fetch!(attrs, :library_path_id)
    relative_path = Map.fetch!(attrs, :relative_path)

    case Repo.get_by(ImportCandidate,
           library_path_id: library_path_id,
           relative_path: relative_path
         ) do
      nil -> insert_or_update(%ImportCandidate{}, attrs, library_path_id, relative_path)
      existing -> insert_or_update(existing, attrs, library_path_id, relative_path)
    end
  end

  @spec get_by_path(binary(), String.t()) :: ImportCandidate.t() | nil
  def get_by_path(library_path_id, relative_path) do
    Repo.get_by(ImportCandidate, library_path_id: library_path_id, relative_path: relative_path)
  end

  @spec delete_missing(binary(), [String.t()]) :: {non_neg_integer(), nil | [term()]}
  def delete_missing(library_path_id, relative_paths) do
    ImportCandidate
    |> where([candidate], candidate.library_path_id == ^library_path_id)
    |> where([candidate], candidate.relative_path not in ^relative_paths)
    |> Repo.delete_all()
  end

  @spec demote_episode_files(Episode.t()) :: {:ok, :ok} | {:error, term()}
  def demote_episode_files(%Episode{} = episode) do
    Repo.transaction(fn ->
      episode = Repo.preload(episode, [:media_item, media_files: :library_path])

      Enum.each(episode.media_files, fn file ->
        library_path = file.library_path

        anchor =
          PathAnchor.anchor_for(
            Path.join(library_path.path, file.relative_path),
            library_path.path
          )

        {provider_type, provider_id} = provider_identity(episode.media_item)

        case upsert(%{
               library_path_id: file.library_path_id,
               relative_path: file.relative_path,
               anchor_key: anchor.cluster_key,
               size: file.size,
               discovered_at: file.inserted_at,
               provider_type: provider_type,
               provider_id: provider_id,
               media_type: "tv_show",
               parsed_info: %{
                 "type" => "tv_show",
                 "season" => episode.season_number,
                 "episodes" => [episode.episode_number]
               }
             }) do
          {:ok, _candidate} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end

        Repo.delete!(file)
      end)

      :ok
    end)
  end

  defp insert_or_update(candidate, attrs, library_path_id, relative_path) do
    case candidate |> ImportCandidate.changeset(attrs) |> Repo.insert_or_update() do
      {:error, %Ecto.Changeset{} = changeset} ->
        case Repo.get_by(ImportCandidate,
               library_path_id: library_path_id,
               relative_path: relative_path
             ) do
          nil -> {:error, changeset}
          existing -> existing |> ImportCandidate.changeset(attrs) |> Repo.update()
        end

      result ->
        result
    end
  end

  defp provider_identity(%{metadata_source: :tmdb, tmdb_id: id}) when not is_nil(id),
    do: {"tmdb", Integer.to_string(id)}

  defp provider_identity(%{metadata_source: :tvdb, tvdb_id: id}) when not is_nil(id),
    do: {"tvdb", Integer.to_string(id)}

  defp provider_identity(%{metadata_source: :tmdb}), do: {"tmdb", nil}
  defp provider_identity(%{metadata_source: :tvdb}), do: {"tvdb", nil}

  defp provider_identity(%{tvdb_id: id}) when not is_nil(id), do: {"tvdb", Integer.to_string(id)}
  defp provider_identity(%{tmdb_id: id}) when not is_nil(id), do: {"tmdb", Integer.to_string(id)}
  defp provider_identity(_), do: {nil, nil}
end
