defmodule Mydia.Library.EpisodeMinter do
  @moduledoc """
  Creates the episode rows a metadata provider is missing.

  Mydia builds episodes from provider metadata, so a provider that has not yet
  published a season leaves every file for it with no parent and on no surface.
  TVDB 447978 sat five weeks behind its own broadcaster and stranded sixteen
  files exactly that way.

  Whether minting is allowed at all is not decided here. Candidate promotion
  owns that through its policy: an accepted unattended import may mint, while
  review mode leaves the candidate for an operator. This module decides only
  whether a coordinate is *plausible* for this show.

  ## The anchor

  A misparse must not be able to invent an episode. Given `{max_season,
  max_episode}` from `Media.episode_bounds/1`, which excludes season 0 so a
  special's episode number can never inflate the ceiling, minting requires:

    * `season_number >= 1`, because season 0 specials are too ragged to guess at
    * `season_number <= max_season + 1`, so season 4 on a show ending at 3
      passes while a misparsed S99 does not
    * `episode_number >= 1 and episode_number <= max(max_episode + 10, 30)`

  The floor of 30 covers a show whose provider returned no episodes at all,
  where a bare `max_episode + 10` would be a ceiling of 10 and would refuse a
  legitimate 22 episode first season.

  There is deliberately no per-group cap. The anchor already bounds the damage,
  because a group of absurd files fails file by file.

  The season ceiling is read fresh on every call, so importing seasons 4 and 5
  together cascades: the season 4 rows land first and raise the ceiling for
  season 5. Out of order, the season 5 files stay outstanding and the next pass
  takes them, because `Jobs.ApplyImportGroups.drain/3` retries while it makes
  progress.

  ## Why the row is untagged

  A minted row carries `provider_episode_id: nil`. `Media.fallback_by_number/2`
  adopts an untagged row at matching coordinates when the provider later
  publishes an episode carrying an id, so `Media.upsert_episodes_from_season/3`
  updates these rows in place with the real title, air date and id rather than
  inserting a second one. The file link, watch history and monitored flag ride
  along.
  """

  require Logger

  alias Mydia.Library.ReleaseParser.EpisodeTitle
  alias Mydia.Media
  alias Mydia.Media.{Episode, MediaItem}

  @episode_margin 10
  @episode_floor 30

  @doc """
  Whether `season_number`/`episode_number` is a plausible coordinate for this show.
  """
  @spec mintable?(MediaItem.t(), term(), term()) :: boolean()
  def mintable?(%MediaItem{} = media_item, season_number, episode_number)
      when is_integer(season_number) and is_integer(episode_number) do
    {max_season, max_episode} = Media.episode_bounds(media_item.id)

    season_number >= 1 and
      season_number <= max_season + 1 and
      episode_number >= 1 and
      episode_number <= max(max_episode + @episode_margin, @episode_floor)
  end

  def mintable?(_media_item, _season_number, _episode_number), do: false

  @doc """
  Creates the episode when the coordinate is plausible.

  Returns the existing row when one is already there, so a retried import does
  not fight the `(media_item_id, season_number, episode_number)` unique index.
  """
  @spec mint(MediaItem.t(), term(), term(), String.t() | nil) ::
          {:ok, Episode.t()} | {:error, :implausible} | {:error, Ecto.Changeset.t()}
  def mint(%MediaItem{} = media_item, season_number, episode_number, filename) do
    if mintable?(media_item, season_number, episode_number) do
      case Media.get_episode_by_number(media_item.id, season_number, episode_number) do
        nil -> create(media_item, season_number, episode_number, filename)
        existing -> {:ok, existing}
      end
    else
      Logger.info("Refusing to create an implausible episode",
        media_item_id: media_item.id,
        season: inspect(season_number),
        episode: inspect(episode_number)
      )

      {:error, :implausible}
    end
  end

  defp create(media_item, season_number, episode_number, filename) do
    attrs = %{
      media_item_id: media_item.id,
      season_number: season_number,
      episode_number: episode_number,
      provider_episode_id: nil,
      title: EpisodeTitle.extract(filename),
      monitored: Media.should_monitor_new_episode?(media_item, season_number)
    }

    case Media.create_episode(attrs) do
      {:ok, episode} ->
        Logger.info("Created an episode the metadata provider is missing",
          media_item_id: media_item.id,
          season: season_number,
          episode: episode_number
        )

        {:ok, episode}

      {:error, changeset} ->
        # A concurrent minter won the unique index. Its row is the answer.
        case Media.get_episode_by_number(media_item.id, season_number, episode_number) do
          nil -> {:error, changeset}
          existing -> {:ok, existing}
        end
    end
  end
end
