defmodule MydiaWeb.MediaLive.Show.EpisodeEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Media
  alias MydiaWeb.Live.Authorization

  import MydiaWeb.MediaLive.Show.Loaders, only: [load_media_item: 1]
  import MydiaWeb.MediaLive.Show.Helpers, only: [monitoring_preset_label: 1]

  require Logger

  # Derived from the context so the two lists cannot drift apart.
  @valid_monitoring_presets Enum.map(Media.monitoring_presets(), &Atom.to_string/1)

  def toggle_monitored(_params, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      media_item = socket.assigns.media_item
      new_monitored = !media_item.monitored

      {:ok, updated_item} =
        Media.update_media_item(media_item, %{monitored: new_monitored},
          reason: if(new_monitored, do: "Monitoring enabled", else: "Monitoring disabled")
        )

      {:noreply,
       socket
       |> assign(:media_item, updated_item)
       |> put_flash(
         :info,
         "Monitoring #{if updated_item.monitored, do: "enabled", else: "disabled"}"
       )}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def apply_episode_monitoring(%{"preset" => preset_str}, socket) do
    with :ok <- Authorization.authorize_update_media(socket),
         true <- preset_str in @valid_monitoring_presets do
      media_item = socket.assigns.media_item
      preset = String.to_existing_atom(preset_str)

      case Media.apply_episode_monitoring(media_item, preset) do
        {:ok, count} ->
          preset_label = monitoring_preset_label(preset)

          {:noreply,
           socket
           |> assign(:media_item, load_media_item(media_item.id))
           |> put_flash(:info, "Applied '#{preset_label}' monitoring to #{count} episodes")}

        {:error, reason} ->
          Logger.error("Failed to apply episode monitoring: #{inspect(reason)}")

          {:noreply, put_flash(socket, :error, "Failed to apply episode monitoring")}
      end
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      false ->
        {:noreply, put_flash(socket, :error, "Invalid monitoring preset")}
    end
  end

  def toggle_monitor_new_seasons(_params, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      media_item = socket.assigns.media_item
      mode = if media_item.monitor_new_seasons == :all, do: :none, else: :all

      {:ok, updated} = Media.set_monitor_new_seasons(media_item, mode)

      message =
        if mode == :all,
          do: "New seasons will be monitored",
          else: "New seasons will not be monitored"

      {:noreply,
       socket
       |> assign(:media_item, load_media_item(updated.id))
       |> put_flash(:info, message)}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def toggle_episode_monitored(%{"episode-id" => episode_id}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      episode = Media.get_episode!(episode_id)
      {:ok, _updated_episode} = Media.update_episode(episode, %{monitored: !episode.monitored})

      {:noreply,
       socket
       |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
       |> put_flash(
         :info,
         "Episode monitoring #{if episode.monitored, do: "disabled", else: "enabled"}"
       )}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def monitor_season(%{"season-number" => season_number_str}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      season_number = String.to_integer(season_number_str)
      media_item = socket.assigns.media_item

      case Media.update_season_monitoring(media_item.id, season_number, true) do
        {:ok, count} ->
          {:noreply,
           socket
           |> assign(:media_item, load_media_item(media_item.id))
           |> put_flash(
             :info,
             "Monitoring enabled for #{count} episodes in Season #{season_number}"
           )}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to update season monitoring")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def unmonitor_season(%{"season-number" => season_number_str}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      season_number = String.to_integer(season_number_str)
      media_item = socket.assigns.media_item

      case Media.update_season_monitoring(media_item.id, season_number, false) do
        {:ok, count} ->
          {:noreply,
           socket
           |> assign(:media_item, load_media_item(media_item.id))
           |> put_flash(
             :info,
             "Monitoring disabled for #{count} episodes in Season #{season_number}"
           )}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to update season monitoring")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def toggle_season_expanded(%{"season-number" => season_number_str}, socket) do
    season_number = String.to_integer(season_number_str)
    expanded_seasons = socket.assigns.expanded_seasons

    updated_seasons =
      if MapSet.member?(expanded_seasons, season_number) do
        MapSet.delete(expanded_seasons, season_number)
      else
        MapSet.put(expanded_seasons, season_number)
      end

    {:noreply, assign(socket, :expanded_seasons, updated_seasons)}
  end

  @doc """
  Toggles one labelled episode range within a season.

  Keyed on `{season_number, label}` rather than the label alone, so the same
  range label in two different seasons does not toggle in lockstep.
  """
  def toggle_episode_chunk(
        %{"season-number" => season_str, "chunk-label" => label},
        socket
      ) do
    key = {String.to_integer(season_str), label}

    expanded =
      if MapSet.member?(socket.assigns.expanded_chunks, key) do
        MapSet.delete(socket.assigns.expanded_chunks, key)
      else
        MapSet.put(socket.assigns.expanded_chunks, key)
      end

    {:noreply, assign(socket, :expanded_chunks, expanded)}
  end

  def toggle_episode_expanded(%{"episode-id" => episode_id}, socket) do
    expanded_episodes = socket.assigns.expanded_episodes

    updated_episodes =
      if MapSet.member?(expanded_episodes, episode_id) do
        MapSet.delete(expanded_episodes, episode_id)
      else
        MapSet.put(expanded_episodes, episode_id)
      end

    {:noreply, assign(socket, :expanded_episodes, updated_episodes)}
  end
end
