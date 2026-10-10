defmodule Mydia.Library.EpisodeLinks do
  @moduledoc """
  Links TV media files to the episodes their filenames name, including multi-episode releases.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Library.{MediaFile, MediaFileEpisode, MediaFiles, Text}
  alias Mydia.Library.ReleaseParser, as: FileParser

  @doc """
  Finds the non-extra media files attached straight to a TV show (a shape only
  rows written before `MediaFile.changeset/2` refused it can have), parses
  their filenames for season/episode information, and associates them with
  the matching episode records. Used by `Mydia.Jobs.ShowFileRepair`.

  Returns `{:ok, matched_count}` where matched_count is the number of files that
  were successfully matched to episodes.

  ## Parameters
    - `media_item_id` - The ID of the TV show media item

  ## Examples

      iex> match_files_to_episodes("some-uuid")
      {:ok, 8}
  """
  @spec match_files_to_episodes(binary()) :: {:ok, non_neg_integer()}
  def match_files_to_episodes(media_item_id) do
    # Files attached straight to the show. Extras may legitimately sit there,
    # so they are left alone even when their name carries an SxxEyy.
    unmatched_files =
      MediaFile
      |> where([mf], mf.media_item_id == ^media_item_id)
      |> where([mf], is_nil(mf.episode_id))
      |> where([mf], is_nil(mf.trashed_at))
      |> where([mf], is_nil(mf.extra_kind))
      |> Repo.all()

    Logger.info(
      "Found #{length(unmatched_files)} unmatched files for media item #{media_item_id}"
    )

    # Title of the show these files are being matched against, used to reject a
    # stray file whose filename clearly belongs to a different show (see
    # title_belongs_to_other_show?/2).
    show_title = media_item_title(media_item_id)

    # Match each file to an episode
    matched_count =
      Enum.reduce(unmatched_files, 0, fn media_file, count ->
        case match_file_to_episode(media_file, media_item_id, show_title) do
          {:ok, _} -> count + 1
          {:error, _} -> count
        end
      end)

    Logger.info("Successfully matched #{matched_count} files to episodes")

    {:ok, matched_count}
  end

  defp match_file_to_episode(media_file, media_item_id, show_title) do
    if is_nil(media_file.relative_path) do
      Logger.warning("Media file missing relative_path during episode matching",
        media_file_id: media_file.id
      )
    end

    with {:ok, episodes} <-
           resolve_file_episodes(media_file.relative_path, media_item_id, show_title) do
      attach_file_to_episodes(media_file, episodes)
    end
  end

  # The episodes a TV file's name refers to, without touching any row. Shared by
  # the legacy re-link above and by the re-scan, which has to know the episode
  # before it creates the row: MediaFile.changeset/2 refuses a TV file attached
  # to the show itself.
  @doc false
  def resolve_file_episodes(nil, _media_item_id, _show_title), do: {:error, :no_relative_path}

  def resolve_file_episodes(relative_path, media_item_id, show_title) do
    filename = Path.basename(relative_path)
    parsed_info = FileParser.parse(filename)
    season = parsed_info.season
    episode_numbers = parsed_info.episodes

    cond do
      not (is_integer(season) and is_list(episode_numbers) and episode_numbers != []) ->
        Logger.debug("File did not contain valid episode information", filename: filename)
        {:error, :no_episode_info}

      title_belongs_to_other_show?(parsed_info.title, show_title) ->
        # A file carrying an SxxEyy pattern must not be bound to this show
        # purely because the numbers line up, e.g. a stray file from another
        # show whose S04E07 happens to exist here too. Guard on the parsed title.
        Logger.debug("Skipping file: parsed title belongs to a different show",
          filename: filename,
          parsed_title: parsed_info.title,
          show_title: show_title
        )

        {:error, :title_mismatch}

      true ->
        # A multi-episode release (S01E09E10) holds every episode it names.
        # Resolve all of them: the first becomes `episode_id` (the primary,
        # which existing queries join on), and every one gets a
        # media_file_episodes row so no episode of the file reads as missing.
        episode_numbers
        |> Enum.map(&Mydia.Media.get_episode_by_number(Scope.system(), media_item_id, season, &1))
        |> Enum.reject(&is_nil/1)
        |> case do
          [] ->
            Logger.debug("No episode found for file",
              filename: filename,
              season: season,
              episode: List.first(episode_numbers)
            )

            {:error, :episode_not_found}

          episodes ->
            {:ok, episodes}
        end
    end
  end

  # Rejects a file whose parsed title clearly belongs to a different show. Only
  # guards when both a parsed title and a show title are present; an
  # unparseable/blank title falls through so ambiguous filenames keep matching
  # on season/episode numbers as before.
  @title_match_threshold 0.5
  @doc false
  def title_belongs_to_other_show?(parsed_title, show_title)
      when is_binary(parsed_title) and is_binary(show_title) and
             parsed_title != "" and show_title != "" do
    Text.title_similarity(parsed_title, show_title) < @title_match_threshold
  end

  def title_belongs_to_other_show?(_parsed_title, _show_title), do: false

  defp media_item_title(media_item_id) do
    case Repo.get(Mydia.Media.MediaItem, media_item_id) do
      %{title: title} -> title
      _ -> nil
    end
  end

  defp attach_file_to_episodes(media_file, [primary | _] = episodes) do
    case MediaFiles.update_media_file(media_file, %{media_item_id: nil, episode_id: primary.id}) do
      {:ok, updated_file} ->
        {:ok, _} = link_file_to_episodes(updated_file, episodes)

        Logger.debug("Matched file to episode",
          relative_path: updated_file.relative_path,
          episode_id: primary.id,
          covers: Enum.map(episodes, & &1.episode_number)
        )

        {:ok, updated_file}

      {:error, reason} ->
        Logger.warning("Failed to update media file",
          relative_path: media_file.relative_path,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Records the full set of episodes a media file covers.

  Authoritative, and idempotent: re-running a scan over an already-linked file
  inserts nothing new, and any episode the file no longer covers has its link
  removed, so a corrected filename does not leave a stale episode still holding
  the file. Use `add_episode_links/2` when the caller only knows part of the set.

  Returns `{:ok, count}` where count is the number of episodes now linked.
  """
  def link_file_to_episodes(%MediaFile{} = media_file, episodes) when is_list(episodes) do
    episode_ids = episodes |> Enum.map(& &1.id) |> Enum.uniq()

    {:ok, _} = add_episode_links(media_file, episode_ids)

    from(mfe in MediaFileEpisode,
      where: mfe.media_file_id == ^media_file.id and mfe.episode_id not in ^episode_ids
    )
    |> Repo.delete_all()

    {:ok, length(episode_ids)}
  end

  @doc """
  Adds episode links without removing any, and without duplicating existing ones.

  Use this when the caller knows some of the episodes a file covers but not
  necessarily all of them. `link_file_to_episodes/2` is the authoritative
  version and prunes links the file no longer covers.
  """
  def add_episode_links(%MediaFile{} = media_file, episode_ids) when is_list(episode_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      episode_ids
      |> Enum.uniq()
      |> Enum.map(fn episode_id ->
        %{
          id: Ecto.UUID.generate(),
          media_file_id: media_file.id,
          episode_id: episode_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all(MediaFileEpisode, rows, on_conflict: :nothing)

    {:ok, count}
  end

  @doc """
  Ensures the file's primary `episode_id` is represented in the join table.

  `Episode.media_files` reads through `media_file_episodes`, so a writer that
  sets `episode_id` without a join row would make the file invisible on the
  episode page. Every generic media-file write funnels through here.

  Purely additive: it never removes links, so it cannot clobber the richer set
  a multi-episode match recorded via `link_file_to_episodes/2`.
  """
  def ensure_episode_link(%MediaFile{episode_id: nil} = media_file), do: {:ok, media_file}

  def ensure_episode_link(%MediaFile{} = media_file) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      MediaFileEpisode,
      [
        %{
          id: Ecto.UUID.generate(),
          media_file_id: media_file.id,
          episode_id: media_file.episode_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    {:ok, media_file}
  end
end
