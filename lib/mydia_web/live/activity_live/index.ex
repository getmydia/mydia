defmodule MydiaWeb.ActivityLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Events
  alias Mydia.Events.Presentation
  alias Phoenix.PubSub

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        # Subscribe to events for real-time updates
        PubSub.subscribe(Mydia.PubSub, "events:all")

        socket
        |> assign(:category_filter, "all")
        |> assign(:date_filter, "all")
        |> assign(:page, 0)
        |> assign(:has_more?, false)
        |> assign(:events_empty?, false)
        |> load_events()
      else
        socket
        |> assign(:category_filter, "all")
        |> assign(:date_filter, "all")
        |> assign(:page, 0)
        |> assign(:has_more?, false)
        |> assign(:events_empty?, true)
        |> stream(:events, [])
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Activity")}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category}, socket) do
    {:noreply,
     socket
     |> assign(:category_filter, category)
     |> assign(:page, 0)
     |> load_events()}
  end

  @impl true
  def handle_event("filter_date", %{"date" => date_preset}, socket) do
    {:noreply,
     socket
     |> assign(:date_filter, date_preset)
     |> assign(:page, 0)
     |> load_events()}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1

    {:noreply,
     socket
     |> assign(:page, next_page)
     |> load_more_events()}
  end

  @impl true
  def handle_info({:event_created, event}, socket) do
    category_filter = socket.assigns.category_filter
    date_filter = socket.assigns.date_filter

    # Types hidden from the feed have their own dedicated viewer elsewhere.
    # This check must mirror build_filter_opts/2, which applies it in SQL.
    feed_visible = event.type not in Presentation.feed_hidden_types()

    # Only add event if it matches current category filter
    matches_category =
      case category_filter do
        "all" -> true
        "errors" -> event.severity == :error
        category -> event.category == category
      end

    # Only add event if it matches current date filter
    matches_date = event_matches_date_filter?(event.inserted_at, date_filter)

    socket =
      if feed_visible && matches_category && matches_date do
        socket
        |> assign(:events_empty?, false)
        |> stream_insert(:events, event, at: 0)
      else
        socket
      end

    {:noreply, socket}
  end

  ## Private Helpers

  defp load_events(socket) do
    category_filter = socket.assigns.category_filter
    date_filter = socket.assigns.date_filter

    filter_opts = build_filter_opts(category_filter, date_filter)

    # Request one more than page_size to check if there are more results
    events = Events.list_events(filter_opts ++ [limit: @page_size + 1, offset: 0])

    has_more? = length(events) > @page_size
    events = Enum.take(events, @page_size)

    socket
    |> assign(:events_empty?, events == [])
    |> assign(:has_more?, has_more?)
    |> stream(:events, events, reset: true)
  end

  defp load_more_events(socket) do
    category_filter = socket.assigns.category_filter
    date_filter = socket.assigns.date_filter
    page = socket.assigns.page

    filter_opts = build_filter_opts(category_filter, date_filter)
    offset = page * @page_size

    # Request one more than page_size to check if there are more results
    events = Events.list_events(filter_opts ++ [limit: @page_size + 1, offset: offset])

    has_more? = length(events) > @page_size
    events = Enum.take(events, @page_size)

    socket =
      Enum.reduce(events, socket, fn event, acc ->
        stream_insert(acc, :events, event)
      end)

    assign(socket, :has_more?, has_more?)
  end

  defp build_filter_opts(category_filter, date_filter) do
    category_opts =
      case category_filter do
        "all" -> []
        "errors" -> [severity: :error]
        category -> [category: category]
      end

    date_opts = date_filter_opts(date_filter)

    category_opts ++ date_opts ++ [exclude_types: Presentation.feed_hidden_types()]
  end

  defp date_filter_opts("all"), do: []
  defp date_filter_opts("today"), do: [since: start_of_day()]

  defp date_filter_opts("yesterday") do
    [since: start_of_yesterday(), until: end_of_yesterday()]
  end

  defp date_filter_opts("week"), do: [since: days_ago(7)]
  defp date_filter_opts("month"), do: [since: days_ago(30)]
  defp date_filter_opts(_), do: []

  defp start_of_day do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp start_of_yesterday do
    DateTime.utc_now()
    |> DateTime.add(-1, :day)
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp end_of_yesterday do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp days_ago(n) do
    DateTime.utc_now() |> DateTime.add(-n, :day)
  end

  defp event_matches_date_filter?(_inserted_at, "all"), do: true

  defp event_matches_date_filter?(inserted_at, "today") do
    DateTime.compare(inserted_at, start_of_day()) != :lt
  end

  defp event_matches_date_filter?(inserted_at, "yesterday") do
    DateTime.compare(inserted_at, start_of_yesterday()) != :lt &&
      DateTime.compare(inserted_at, end_of_yesterday()) == :lt
  end

  defp event_matches_date_filter?(inserted_at, "week") do
    DateTime.compare(inserted_at, days_ago(7)) != :lt
  end

  defp event_matches_date_filter?(inserted_at, "month") do
    DateTime.compare(inserted_at, days_ago(30)) != :lt
  end

  defp event_matches_date_filter?(_inserted_at, _), do: true

  ## UI Helpers

  defp event_icon(event), do: Presentation.for_event(event).icon

  defp event_summary(event) do
    presentation = Presentation.for_event(event)

    case presentation.detail do
      nil -> presentation.title
      detail -> "#{presentation.title}: #{detail}"
    end
  end

  defp format_actor(event) do
    case event.actor_type do
      :user -> "User"
      :system -> "System"
      :job -> format_job_name(event.actor_id)
      nil -> "System"
      _ -> "Unknown"
    end
  end

  defp format_job_name(nil), do: "Job"
  defp format_job_name("movie_search"), do: "Movie Search"
  defp format_job_name("tv_show_search"), do: "TV Search"
  defp format_job_name("episode_search"), do: "Episode Search"
  defp format_job_name("season_search"), do: "Season Search"
  defp format_job_name("metadata_sync"), do: "Metadata Sync"
  defp format_job_name("library_scan"), do: "Library Scan"

  defp format_job_name(job_id) do
    # Handle full module names like "Mydia.Jobs.TvShowSearch"
    name =
      if String.contains?(job_id, ".") do
        job_id
        |> String.split(".")
        |> List.last()
      else
        job_id
      end

    # Convert CamelCase or snake_case to readable format
    name
    |> String.replace("_", " ")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp actor_icon(event) do
    case event.actor_type do
      :user -> "hero-user"
      :job -> "hero-cog-6-tooth"
      :system -> "hero-computer-desktop"
      _ -> "hero-computer-desktop"
    end
  end

  defp severity_badge_class(severity) do
    case severity do
      :error -> "badge-error"
      :warning -> "badge-warning"
      :info -> "badge-info"
      _ -> "badge-ghost"
    end
  end

  defp relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} minutes ago"
      diff < 86400 -> "#{div(diff, 3600)} hours ago"
      diff < 604_800 -> "#{div(diff, 86400)} days ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end

  defp has_search_details?(event) do
    event.category == "search" &&
      (event.metadata["query"] != nil ||
         event.metadata["results_count"] != nil ||
         event.metadata["filter_stats"] != nil ||
         event.metadata["breakdown"] != nil)
  end

  defp has_update_details?(event) do
    event.type == "media_item.updated" &&
      event.metadata["changes"] != nil &&
      event.metadata["changes"] != %{}
  end

  defp has_job_failure_details?(event) do
    event.type == "job.failed" &&
      (event.metadata["stacktrace"] != nil ||
         event.metadata["queue"] != nil ||
         event.metadata["attempt"] != nil)
  end

  # Formats the detailed list of changes for the expandable view
  defp format_change_details(changes) when is_nil(changes), do: []
  defp format_change_details(changes) when changes == %{}, do: []

  defp format_change_details(changes) do
    simple_changes =
      changes
      |> Map.take(["title", "original_title", "year"])
      |> Enum.map(fn {field, change} ->
        %{
          field: humanize_field_name(field),
          old: format_change_value(field, change["old"]),
          new: format_change_value(field, change["new"])
        }
      end)

    metadata_changes =
      case Map.get(changes, "metadata_fields") do
        nil ->
          []

        fields when is_list(fields) ->
          Enum.map(fields, fn field_change ->
            %{
              field: humanize_field_name(field_change["field"]),
              old: format_metadata_change_value(field_change["field"], field_change["old"]),
              new: format_metadata_change_value(field_change["field"], field_change["new"])
            }
          end)

        _ ->
          []
      end

    simple_changes ++ metadata_changes
  end

  defp humanize_field_name("overview"), do: "Description"
  defp humanize_field_name("poster"), do: "Poster"
  defp humanize_field_name("backdrop"), do: "Backdrop"
  defp humanize_field_name("tagline"), do: "Tagline"
  defp humanize_field_name("rating"), do: "Rating"
  defp humanize_field_name("runtime"), do: "Runtime"
  defp humanize_field_name("genres"), do: "Genres"
  defp humanize_field_name("cast"), do: "Cast"
  defp humanize_field_name("crew"), do: "Crew"
  defp humanize_field_name("title"), do: "Title"
  defp humanize_field_name("original_title"), do: "Original Title"
  defp humanize_field_name("year"), do: "Year"
  defp humanize_field_name(field), do: Phoenix.Naming.humanize(field)

  defp format_change_value(_field, nil), do: "none"
  defp format_change_value(_field, value), do: to_string(value)

  defp format_metadata_change_value("rating", nil), do: "none"
  defp format_metadata_change_value("rating", value) when is_number(value), do: "#{value}/10"
  defp format_metadata_change_value("genres", nil), do: "none"
  defp format_metadata_change_value("genres", count) when is_integer(count), do: "#{count} genres"
  defp format_metadata_change_value("cast", 0), do: "none"
  defp format_metadata_change_value("cast", count) when is_integer(count), do: "#{count} members"
  defp format_metadata_change_value("crew", 0), do: "none"
  defp format_metadata_change_value("crew", count) when is_integer(count), do: "#{count} members"
  defp format_metadata_change_value(_field, true), do: "added"
  defp format_metadata_change_value(_field, nil), do: "none"
  defp format_metadata_change_value(_field, value), do: to_string(value)

  defp format_filter_stat_label(key) do
    case key do
      "total_results" -> "Total"
      "below_quality_threshold" -> "Below quality"
      "no_valid_season_packs" -> "No season packs"
      # New detailed rejection reasons
      "individual_episode" -> "Episode"
      "missing_season_marker" -> "No season"
      # Hard removals only — size/seeders/ratio are penalties now, not rejections
      "blocked_tag" -> "Blocked"
      "invalid" -> "Invalid"
      "title_mismatch" -> "Wrong show"
      _ -> String.replace(key, "_", " ") |> String.capitalize()
    end
  end

  defp format_breakdown_label(key) do
    case key do
      "quality" -> "Quality"
      "seeders" -> "Seeders"
      "size" -> "Size"
      "age" -> "Age"
      "tag_bonus" -> "Tag bonus"
      "preferred_tags" -> "Preferred"
      "blocked_tags" -> "Blocked"
      "custom_format" -> "Custom format"
      "custom_format_score" -> "Custom format"
      "title_relevance" -> "Title match"
      "title_match" -> "Title match"
      # Soft-penalty contributions
      "size_penalty" -> "Size penalty"
      "seeder_penalty" -> "Seeder penalty"
      "identity_penalty" -> "Identity mismatch"
      _ -> String.replace(key, "_", " ") |> String.capitalize()
    end
  end

  defp format_breakdown_value(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 1)
  end

  defp format_breakdown_value(value), do: to_string(value)

  # Tooltip summary of the non-zero penalty contributions on an accepted result.
  defp format_penalty_summary(penalties) when is_map(penalties) do
    penalties
    |> Enum.filter(fn {_key, value} -> is_number(value) and value < 0.0 end)
    |> Enum.map_join(", ", fn {key, value} ->
      "#{format_breakdown_label(key)}: #{trunc(value)}"
    end)
  end

  defp format_penalty_summary(_), do: ""
end
