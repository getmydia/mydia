defmodule Mydia.Library.MultiEpisodeRelink do
  @moduledoc """
  Repairs libraries that were scanned before multi-episode files were supported.

  A release such as `S01E09E10` holds two episodes. Until `media_file_episodes`
  existed, the matcher bound the file to the first episode only and dropped the
  rest, so every trailing episode read as un-downloaded while its content sat on
  disk in the very file the previous episode was playing.

  Re-scanning does not fix those files: `Library.match_files_to_episodes/1` only
  considers rows where `episode_id IS NULL`, and these already have one. This
  module walks the already-matched files and adds the links that were dropped.

  Safe to run repeatedly. It only ever adds links for episodes the filename
  actually names, and never touches a file whose filename names a single
  episode.
  """

  import Ecto.Query

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Library.ReleaseParser
  alias Mydia.Media
  alias Mydia.Media.Episode
  alias Mydia.Repo

  require Logger

  @doc """
  Adds the missing episode links across the whole library.

  Returns `{:ok, %{files_relinked: n, links_added: m}}`.
  """
  def run do
    result =
      candidates()
      |> Enum.reduce(%{files_relinked: 0, links_added: 0}, fn {media_file, media_item_id, season},
                                                              acc ->
        case relink(media_file, media_item_id, season) do
          {:ok, added} when added > 0 ->
            %{acc | files_relinked: acc.files_relinked + 1, links_added: acc.links_added + added}

          _ ->
            acc
        end
      end)

    if result.files_relinked > 0 do
      Logger.info(
        "Relinked #{result.files_relinked} multi-episode files, " <>
          "adding #{result.links_added} episode links"
      )
    end

    {:ok, result}
  end

  # Every matched, untrashed TV file, paired with the show and season its
  # primary episode belongs to. The parse decides whether it is interesting;
  # SQLite has no portable regex, so the filter happens in Elixir.
  defp candidates do
    from(mf in MediaFile,
      join: e in Episode,
      on: e.id == mf.episode_id,
      where: is_nil(mf.trashed_at),
      where: not is_nil(mf.relative_path),
      select: {mf, e.media_item_id, e.season_number}
    )
    |> Repo.all()
  end

  defp relink(%MediaFile{} = media_file, media_item_id, season) do
    parsed = media_file.relative_path |> Path.basename() |> ReleaseParser.parse()

    episode_numbers = parsed.episodes || []

    # Only multi-episode filenames are of interest. Trust the season already
    # recorded on the primary episode over the parse, which can misread a
    # folder-less path.
    if length(episode_numbers) > 1 do
      episodes =
        episode_numbers
        |> Enum.map(&Media.get_episode_by_number(media_item_id, season, &1))
        |> Enum.reject(&is_nil/1)

      link_if_new(media_file, episodes)
    else
      {:ok, 0}
    end
  end

  defp link_if_new(_media_file, episodes) when length(episodes) < 2, do: {:ok, 0}

  defp link_if_new(%MediaFile{} = media_file, episodes) do
    # Strictly additive, so a link this repair does not know about survives.
    Library.add_episode_links(media_file, Enum.map(episodes, & &1.id))
  end
end
