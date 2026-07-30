defmodule MydiaWeb.CalendarLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Media

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    end

    today = Date.utc_today()

    {:ok,
     socket
     |> assign(:current_date, today)
     |> assign(:selected_month, today.month)
     |> assign(:selected_year, today.year)
     |> assign(:filter_type, nil)
     |> assign(:calendar_items, [])
     |> load_calendar_items()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :page_title, "Calendar")}
  end

  @impl true
  def handle_event("prev_month", _params, socket) do
    date = Date.new!(socket.assigns.selected_year, socket.assigns.selected_month, 1)
    prev_month = Date.add(date, -1)

    {:noreply,
     socket
     |> assign(:selected_month, prev_month.month)
     |> assign(:selected_year, prev_month.year)
     |> load_calendar_items()}
  end

  def handle_event("next_month", _params, socket) do
    date = Date.new!(socket.assigns.selected_year, socket.assigns.selected_month, 1)
    next_month = Date.add(date, 31)

    {:noreply,
     socket
     |> assign(:selected_month, next_month.month)
     |> assign(:selected_year, next_month.year)
     |> load_calendar_items()}
  end

  def handle_event("today", _params, socket) do
    today = Date.utc_today()

    {:noreply,
     socket
     |> assign(:current_date, today)
     |> assign(:selected_month, today.month)
     |> assign(:selected_year, today.year)
     |> load_calendar_items()}
  end

  def handle_event("filter", %{"type" => type}, socket) do
    filter_type =
      case type do
        "all" -> nil
        "movie" -> "movie"
        "tv_show" -> "tv_show"
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:filter_type, filter_type)
     |> load_calendar_items()}
  end

  def handle_event("view_item", %{"id" => id, "type" => type}, socket) do
    case type do
      "episode" ->
        episode = Media.get_episode!(id, preload: [:media_item])
        {:noreply, push_navigate(socket, to: ~p"/media/#{episode.media_item_id}")}

      "movie" ->
        {:noreply, push_navigate(socket, to: ~p"/media/#{id}")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:download_updated, _download_id}, socket) do
    # Just trigger a re-render to update the downloads counter in the sidebar
    # The counter will be recalculated when the layout renders
    {:noreply, socket}
  end

  # Grab outcomes are broadcast on the "downloads" topic and handled by
  # MediaLive.Show, which owns the manual-search UI. Ignore them quietly here
  # so the catch-all below keeps meaning "genuinely unexpected message".
  def handle_info({:grab_completed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:grab_failed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:grab_duplicate, _payload}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    # Catch-all for unhandled messages to prevent crashes
    Logger.warning("Unhandled message in CalendarLive.Index: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_calendar_items(socket) do
    start_date = Date.new!(socket.assigns.selected_year, socket.assigns.selected_month, 1)
    end_date = Date.end_of_month(start_date)

    # Load episodes (all, regardless of monitored status)
    episodes = Media.list_episodes_by_air_date(start_date, end_date, monitored: nil)

    # Load movies (all, regardless of monitored status)
    movies = Media.list_movies_by_release_date(start_date, end_date, monitored: nil)

    # Combine and filter
    items =
      (episodes ++ movies)
      |> apply_type_filter(socket.assigns.filter_type)
      |> Enum.sort_by(& &1.air_date, Date)

    # Group by date
    grouped_items =
      items
      |> Enum.group_by(& &1.air_date)

    # Generate calendar days
    calendar_days = generate_calendar_days(start_date, end_date, grouped_items)

    socket
    |> assign(:calendar_items, items)
    |> assign(:grouped_items, grouped_items)
    |> assign(:calendar_days, calendar_days)
    |> assign(:calendar_empty?, items == [])
  end

  defp apply_type_filter(items, nil), do: items

  defp apply_type_filter(items, filter_type) do
    Enum.filter(items, fn item ->
      case item.type do
        "episode" -> filter_type == "tv_show"
        "movie" -> filter_type == "movie"
        _ -> false
      end
    end)
  end

  defp generate_calendar_days(start_date, end_date, grouped_items) do
    # Get first day of month and calculate padding
    first_day_of_week = Date.day_of_week(start_date)
    # Adjust for Monday as first day of week (1 = Monday, 7 = Sunday)
    padding_days = first_day_of_week - 1

    # Generate list of days
    days_in_month = Date.diff(end_date, start_date) + 1

    # Create padding for empty cells before the month starts
    padding =
      if padding_days > 0 do
        Enum.map(1..padding_days, fn _ -> nil end)
      else
        []
      end

    # Create actual month days
    month_days =
      Enum.map(1..days_in_month, fn day ->
        date = Date.add(start_date, day - 1)
        items = Map.get(grouped_items, date, [])

        %{
          date: date,
          day: day,
          items: items,
          is_today: date == Date.utc_today()
        }
      end)

    padding ++ month_days
  end

  defp format_month_year(month, year) do
    date = Date.new!(year, month, 1)
    Calendar.strftime(date, "%B %Y")
  end

  defp get_item_status(item) do
    today = Date.utc_today()

    cond do
      item.has_files -> :downloaded
      Date.compare(item.air_date, today) == :gt -> :upcoming
      item.has_downloads -> :downloading
      true -> :missing
    end
  end

  defp status_color(status) do
    case status do
      :upcoming -> "bg-base-300 text-base-content/70"
      :downloading -> "bg-info text-info-content"
      :downloaded -> "bg-success text-success-content"
      :missing -> "bg-error text-error-content"
    end
  end

  defp format_episode(item) do
    "S#{String.pad_leading("#{item.season_number}", 2, "0")}E#{String.pad_leading("#{item.episode_number}", 2, "0")}"
  end
end
