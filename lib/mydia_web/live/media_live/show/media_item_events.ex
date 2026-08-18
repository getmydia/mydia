defmodule MydiaWeb.MediaLive.Show.MediaItemEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2, start_async: 3, connected?: 1]

  alias Mydia.Media
  alias Mydia.Media.SeasonOrder
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.MediaLive.Show.Loaders

  import MydiaWeb.MediaLive.Show.Helpers, only: [media_type_path: 1]

  require Logger

  # Above this many episodes in one season, offer an alternative ordering.
  # 60 clears the largest legitimate single season seen in the production
  # library (Bluey at 52) and sits far below the case this exists for
  # (Black Clover at 170).
  @suggest_threshold 60

  def show_delete_confirm(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_confirm, true)
     |> assign(:delete_files, true)}
  end

  def hide_delete_confirm(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_confirm, false)
     |> assign(:delete_files, false)}
  end

  def toggle_delete_files(%{"delete_files" => value}, socket) do
    delete_files = value == "true"
    Logger.info("toggle_delete_files", value: value, delete_files: delete_files)
    {:noreply, assign(socket, :delete_files, delete_files)}
  end

  def delete_media(_params, socket) do
    with :ok <- Authorization.authorize_delete_media(socket) do
      media_item = socket.assigns.media_item
      delete_files = socket.assigns.delete_files

      Logger.info("LiveView delete_media event",
        media_item_id: media_item.id,
        title: media_item.title,
        delete_files: delete_files
      )

      case Media.delete_media_item(media_item, delete_files: delete_files) do
        {:ok, _item, 0} ->
          message =
            if delete_files do
              "#{media_item.title} deleted successfully (including files)"
            else
              "#{media_item.title} removed from library (files preserved)"
            end

          {:noreply,
           socket
           |> put_flash(:info, message)
           |> push_navigate(to: media_type_path(media_item.type))}

        {:ok, _item, error_count} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "#{media_item.title} removed, but #{error_count} #{pluralize_files(error_count)} " <>
               "could not be deleted from disk. Check permissions and remove them manually."
           )
           |> push_navigate(to: media_type_path(media_item.type))}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to delete #{media_item.title}")
           |> assign(:show_delete_confirm, false)}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  defp pluralize_files(1), do: "file"
  defp pluralize_files(_), do: "files"

  # Season ordering

  @doc """
  Starts the season-order-suggestion lookup on the connected mount.

  Eligibility is checked entirely from local data (no network), so the
  (multi-request) TVDB lookup only ever fires for a TVDB show with no
  recorded ordering and an official season that actually looks wrong. Every
  other show never pays for it, and the disconnected (dead) render never
  does either — same convention as `FranchiseEvents.maybe_load/1`.
  """
  def maybe_load_season_order_suggestion(socket) do
    socket = assign(socket, :season_order_suggestion, nil)
    media_item = socket.assigns.media_item

    if connected?(socket) and eligible_for_season_order_suggestion?(media_item) do
      config = socket.assigns.metadata_config

      start_async(socket, :load_season_order_suggestion, fn ->
        SeasonOrder.suggest_alternative(media_item, config)
      end)
    else
      socket
    end
  end

  def handle_season_order_suggestion_result({:ok, {:ok, counts}}, socket) do
    {:noreply, assign(socket, :season_order_suggestion, %{order: :dvd, counts: counts})}
  end

  def handle_season_order_suggestion_result({:ok, {:error, reason}}, socket) do
    Logger.debug("No season order suggestion",
      media_item_id: socket.assigns.media_item.id,
      reason: inspect(reason)
    )

    {:noreply, socket}
  end

  def handle_season_order_suggestion_result({:exit, reason}, socket) do
    Logger.warning("Season order suggestion lookup crashed",
      media_item_id: socket.assigns.media_item.id,
      reason: inspect(reason)
    )

    {:noreply, socket}
  end

  defp eligible_for_season_order_suggestion?(media_item) do
    media_item.type == "tv_show" and
      media_item.metadata_source == :tvdb and
      is_nil(media_item.season_order) and
      oversized_season?(media_item.episodes)
  end

  defp oversized_season?(episodes) do
    episodes
    |> Enum.group_by(& &1.season_number)
    |> Enum.any?(fn {_season_number, eps} -> length(eps) > @suggest_threshold end)
  end

  @doc """
  Switches the show to a different TVDB season ordering.

  Choosing any ordering — including the official one, via the banner's
  "keep aired order" action — records it on `season_order`, which is what
  retires the suggestion banner: it only ever shows for `season_order: nil`.
  """
  def change_season_order(%{"order" => order_param}, socket) do
    case Enum.find(SeasonOrder.values(), &(Atom.to_string(&1) == order_param)) do
      nil -> {:noreply, put_flash(socket, :error, "Unknown episode ordering: #{order_param}")}
      target -> do_change_season_order(target, socket)
    end
  end

  defp do_change_season_order(target, socket) do
    media_item = socket.assigns.media_item
    config = socket.assigns.metadata_config

    case SeasonOrder.switch(media_item, target, config) do
      {:ok, :confirmed} ->
        {:noreply,
         socket
         |> assign(:media_item, Loaders.load_media_item(media_item.id))
         |> assign(:season_order_suggestion, nil)
         |> put_flash(:info, "Keeping #{SeasonOrder.label(target)}.")}

      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:media_item, Loaders.load_media_item(media_item.id))
         |> assign(:season_order_suggestion, nil)
         |> put_flash(
           :info,
           "Switched to #{SeasonOrder.label(target)} — #{count} episode(s) remapped."
         )}

      {:error, {:incomplete_ordering, missing_count}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "TVDB's #{SeasonOrder.label(target)} is missing #{missing_count} of this show's " <>
             "episodes, so nothing was changed."
         )}

      {:error, :missing_provider_ids} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Some of this show's episodes are missing their provider id. Refresh this " <>
             "show's metadata, then try again."
         )}

      {:error, :conflicting_mapping} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That ordering would place two episodes on the same season and episode " <>
             "number, so nothing was changed."
         )}

      {:error, :no_alternative_ordering} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "TVDB does not offer a #{SeasonOrder.label(target)} ordering for this show."
         )}

      {:error, :missing_tvdb_id} ->
        {:noreply,
         put_flash(socket, :error, "This show has no TVDB id to look up orderings from.")}

      {:error, reason} ->
        Logger.warning("change_season_order failed",
          media_item_id: media_item.id,
          target: target,
          reason: inspect(reason)
        )

        {:noreply,
         put_flash(socket, :error, "Could not fetch that ordering from TVDB. Try again later.")}
    end
  end
end
