defmodule Mydia.Indexers.QualityProfileResolver do
  @moduledoc """
  Resolves the quality profile a search should rank its results against.

  A media item with no `quality_profile_id` used to arrive at
  `Mydia.Indexers.RankingOptions.build/1` as a bare `nil`, which silently
  dropped every size, resolution, and seed-ratio bound. The release was then
  ranked on seeders alone and nothing anywhere recorded that the bounds had
  been skipped.

  This module is the one place the three search paths (the TV job, the movie
  job, and the manual search dialog) resolve that profile, so they cannot
  drift apart the way their hand-rolled helpers did:

    1. the media item's own `:quality_profile`
    2. the instance default (`media.default_quality_profile_id`)
    3. `nil`, logged as a warning

  `RankingOptions.build/1` is deliberately left untouched. Its `nil`
  fall-through is still the correct behaviour for a search that genuinely has
  no profile, and keeping it free of database reads is what lets it stay a
  pure builder with pure unit tests.
  """

  require Logger

  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.QualityProfile

  @doc """
  Returns the quality profile to rank `media_item`'s search against, or `nil`
  when the item has none and no instance default is configured.

  `Repo.preload/2` is a no-op when `:quality_profile` is already loaded, so
  callers that hold a preloaded item (the manual search dialog) pay no query.

  Takes a `%MediaItem{}` and nothing else. Every caller has one in hand, so a
  `nil` here is a bug worth raising on rather than quietly absorbing.
  """
  @spec resolve(MediaItem.t()) :: QualityProfile.t() | nil
  def resolve(%MediaItem{} = media_item) do
    # A deleted profile nils the FK (`on_delete: :nilify_all`), so a missing
    # profile and a never-assigned one both surface here as `nil`.
    case Repo.preload(media_item, :quality_profile).quality_profile do
      %QualityProfile{} = profile -> profile
      nil -> fall_back(media_item)
    end
  end

  defp fall_back(%MediaItem{} = media_item) do
    case Settings.get_default_quality_profile() do
      %QualityProfile{} = profile ->
        Logger.info(
          "Media item has no quality profile, ranking against the instance default",
          media_item_id: media_item.id,
          quality_profile: profile.name
        )

        profile

      nil ->
        Logger.warning(
          "Media item has no quality profile and no instance default is configured, " <>
            "searching with no size or resolution bounds",
          media_item_id: media_item.id
        )

        nil
    end
  end
end
