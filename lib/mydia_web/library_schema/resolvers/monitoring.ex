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

  # The strings the media page's own toggles pass, so the activity feed reads the
  # same whichever surface made the change.
  defp reason(true), do: "Monitoring enabled"
  defp reason(false), do: "Monitoring disabled"

  defp item_payload(id), do: %{media_item: Loaders.item_map(id), user_errors: []}

  defp item_failure({:error, %UserError{} = error}), do: %{media_item: nil, user_errors: [error]}

  defp item_failure({:error, %Ecto.Changeset{} = changeset}),
    do: %{media_item: nil, user_errors: UserError.from_changeset(changeset, [])}
end
