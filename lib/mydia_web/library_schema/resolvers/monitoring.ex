defmodule MydiaWeb.LibrarySchema.Resolvers.Monitoring do
  @moduledoc """
  Resolves the monitoring mutations.

  Each calls the function the media page's own toggle calls, with the same
  arguments. Only `update_media_item/3` records who acted;
  `update_season_monitoring/3`, `update_episode/2` and
  `apply_episode_monitoring/2` take no actor.
  """

  alias Mydia.LibraryApi.Principal
  alias Mydia.Media
  alias MydiaWeb.LibrarySchema.Loaders
  alias MydiaWeb.LibrarySchema.MediaItemView
  alias MydiaWeb.LibrarySchema.UserError

  @spec set_media_item_monitored(any(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def set_media_item_monitored(_parent, %{id: id, monitored: monitored}, resolution) do
    opts = Principal.actor_opts(resolution.context.principal) ++ [reason: reason(monitored)]

    with {:ok, item} <- Loaders.item(id, ["id"]),
         {:ok, _updated} <- Media.update_media_item(item, %{monitored: monitored}, opts) do
      {:ok, item_payload(item.id)}
    else
      error -> {:ok, item_failure(error)}
    end
  end

  @spec set_season_monitored(any(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def set_season_monitored(_parent, args, _resolution) do
    %{media_item_id: id, season: season, monitored: monitored} = args

    with {:ok, item} <- Loaders.item(id, ["mediaItemId"]),
         :ok <- Loaders.require_show(item, ["mediaItemId"]),
         {:ok, count} <- Media.update_season_monitoring(item.id, season, monitored),
         :ok <- require_updated(count, season) do
      {:ok, item_payload(item.id)}
    else
      error -> {:ok, item_failure(error)}
    end
  end

  @spec set_episode_monitored(any(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def set_episode_monitored(_parent, %{id: id, monitored: monitored}, _resolution) do
    with {:ok, episode} <- Loaders.episode(id, ["id"]),
         {:ok, _updated} <- Media.update_episode(episode, %{monitored: monitored}),
         {:ok, reloaded} <- Loaders.episode(episode.id, ["id"]) do
      {:ok, %{episode: MediaItemView.episode_map(reloaded), user_errors: []}}
    else
      {:error, %UserError{} = error} ->
        {:ok, %{episode: nil, user_errors: [error]}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:ok, %{episode: nil, user_errors: UserError.from_changeset(changeset, [])}}
    end
  end

  @spec apply_episode_monitoring(any(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def apply_episode_monitoring(_parent, %{media_item_id: id, preset: preset}, _resolution) do
    with {:ok, item} <- Loaders.item(id, ["mediaItemId"]),
         {:ok, _count} <- Media.apply_episode_monitoring(item, preset) do
      {:ok, item_payload(item.id)}
    else
      {:error, {:invalid_type, message}} ->
        {:ok, item_failure({:error, UserError.new(:invalid_input, message, ["mediaItemId"])})}

      {:error, {:invalid_preset, message}} ->
        {:ok, item_failure({:error, UserError.new(:invalid_input, message, ["preset"])})}

      error ->
        {:ok, item_failure(error)}
    end
  end

  # update_season_monitoring/3 updates every episode row in the season, so zero
  # means the season has no episodes; succeeding silently would hide a typo.
  defp require_updated(0, season),
    do: {:error, UserError.new(:not_found, "Season #{season} has no episodes", ["season"])}

  defp require_updated(_count, _season), do: :ok

  # The strings the media page's own toggles pass, so the activity feed reads the
  # same whichever surface made the change.
  defp reason(true), do: "Monitoring enabled"
  defp reason(false), do: "Monitoring disabled"

  defp item_payload(id), do: %{media_item: Loaders.item_map(id), user_errors: []}

  defp item_failure({:error, %UserError{} = error}), do: %{media_item: nil, user_errors: [error]}

  defp item_failure({:error, %Ecto.Changeset{} = changeset}),
    do: %{media_item: nil, user_errors: UserError.from_changeset(changeset, [])}

  defp item_failure({:error, _reason}),
    do: %{
      media_item: nil,
      user_errors: [UserError.new(:invalid_input, "The change could not be saved")]
    }
end
