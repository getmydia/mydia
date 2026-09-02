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

  # Rows are read a page at a time, keyed on media_file id, so a large library
  # is never held in memory at once and each page is written before the next is
  # read. Only files whose *name* parses to more than one episode cost any
  # episode lookups, which on a real library is a small minority.
  @batch_size 500

  @doc """
  Adds the missing episode links across the whole library.

  ## Options

    * `:batch_size` - rows per page (default #{@batch_size}). Exists so tests can
      force the pagination boundary without inserting a full page of fixtures.

  Returns `{:ok, %{files_relinked: n, links_added: m}}`.
  """
  def run(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    result = reduce_batches(nil, %{files_relinked: 0, links_added: 0}, batch_size)

    if result.files_relinked > 0 do
      Logger.info(
        "Relinked #{result.files_relinked} multi-episode files, " <>
          "adding #{result.links_added} episode links"
      )
    end

    {:ok, result}
  end

  defp reduce_batches(after_id, acc, batch_size) do
    case candidates(after_id, batch_size) do
      [] ->
        acc

      batch ->
        acc = Enum.reduce(batch, acc, &relink_row/2)
        {last_id, _, _, _} = List.last(batch)
        reduce_batches(last_id, acc, batch_size)
    end
  end

  defp relink_row({id, relative_path, media_item_id, season}, acc) do
    case relink(id, relative_path, media_item_id, season) do
      {:ok, added} when added > 0 ->
        %{acc | files_relinked: acc.files_relinked + 1, links_added: acc.links_added + added}

      _ ->
        acc
    end
  end

  # One page of matched, untrashed TV files, paired with the show and season the
  # primary episode belongs to. Only the four columns the parse needs are read;
  # the parse decides whether a row is interesting, since SQLite has no portable
  # regex to filter multi-episode names in SQL.
  defp candidates(after_id, batch_size) do
    from(mf in MediaFile,
      join: e in Episode,
      on: e.id == mf.episode_id,
      where: is_nil(mf.trashed_at),
      where: not is_nil(mf.relative_path),
      order_by: [asc: mf.id],
      limit: ^batch_size,
      select: {mf.id, mf.relative_path, e.media_item_id, e.season_number}
    )
    |> then(fn query ->
      if after_id, do: where(query, [mf], mf.id > ^after_id), else: query
    end)
    |> Repo.all()
  end

  defp relink(id, relative_path, media_item_id, season) do
    parsed = relative_path |> Path.basename() |> ReleaseParser.parse()

    episode_numbers = parsed.episodes || []

    # Only multi-episode filenames are of interest. Trust the season already
    # recorded on the primary episode over the parse, which can misread a
    # folder-less path.
    if length(episode_numbers) > 1 do
      episodes =
        episode_numbers
        |> Enum.map(&Media.get_episode_by_number(media_item_id, season, &1))
        |> Enum.reject(&is_nil/1)

      link_if_new(id, episodes)
    else
      {:ok, 0}
    end
  end

  defp link_if_new(_id, episodes) when length(episodes) < 2, do: {:ok, 0}

  defp link_if_new(id, episodes) do
    # Strictly additive, so a link this repair does not know about survives.
    # Only the id is needed; the row itself was never loaded.
    Library.add_episode_links(%MediaFile{id: id}, Enum.map(episodes, & &1.id))
  end
end
