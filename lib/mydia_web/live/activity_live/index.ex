defmodule MydiaWeb.ActivityLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Events
  alias Mydia.Events.Presentation
  alias Mydia.Events.Visibility
  alias MydiaWeb.ActivityLive.DateFilter
  alias Phoenix.PubSub

  @page_size 50

  # The chip catalog lives here rather than in Mydia.Events.Visibility so that
  # daisyUI classes and hero icon names stay out of a context module. Visibility
  # answers which categories a viewer can encounter; this decides how they look.
  # "all" and "errors" are not categories: "all" clears the filter and "errors"
  # filters on severity, so only "all" survives for a restricted viewer.
  # Labels are not part of the catalog: attributes are evaluated at compile
  # time, so chip_label/1 translates them at render time.
  @chips [
    %{
      value: "all",
      icon: "hero-squares-2x2",
      active_class: "btn-primary",
      idle_class: "btn-ghost"
    },
    %{
      value: "media",
      icon: "hero-film",
      active_class: "btn-primary",
      idle_class: "btn-ghost"
    },
    %{
      value: "downloads",
      icon: "hero-arrow-down-tray",
      active_class: "btn-primary",
      idle_class: "btn-ghost"
    },
    %{
      value: "search",
      icon: "hero-magnifying-glass",
      active_class: "btn-primary",
      idle_class: "btn-ghost"
    },
    %{
      value: "system",
      icon: "hero-cog-6-tooth",
      active_class: "btn-primary",
      idle_class: "btn-ghost"
    },
    %{
      value: "playback",
      icon: "hero-play",
      active_class: "btn-primary",
      idle_class: "btn-ghost"
    },
    %{
      value: "plugin",
      icon: "hero-puzzle-piece",
      active_class: "btn-primary",
      idle_class: "btn-ghost"
    },
    %{
      value: "errors",
      icon: "hero-exclamation-triangle",
      active_class: "btn-error",
      idle_class: "btn-ghost text-error/70 hover:text-error"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        # Subscribe to events for real-time updates
        PubSub.subscribe(Mydia.PubSub, "events:all")

        socket
        |> assign(:category_filter, "all")
        |> assign(:date_filter, "all")
        |> assign(:filter_chips, filter_chips(socket.assigns.current_user))
        |> assign(:page, 0)
        |> assign(:has_more?, false)
        |> assign(:events_empty?, false)
        |> load_events()
      else
        socket
        |> assign(:category_filter, "all")
        |> assign(:date_filter, "all")
        |> assign(:filter_chips, filter_chips(socket.assigns.current_user))
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
     |> assign(:page_title, gettext("Activity"))}
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

    # Viewer scoping needs no mirroring: this predicate and the SQL clause
    # applied by Events.list_visible_events/2 are compiled from the same policy.
    viewer_visible = Visibility.visible?(event, socket.assigns.current_user)

    # Only add event if it matches current category filter
    matches_category =
      case category_filter do
        "all" -> true
        "errors" -> event.severity == :error
        category -> event.category == category
      end

    # Only add event if it matches current date filter
    matches_date =
      DateFilter.matches?(
        event.inserted_at,
        date_filter,
        DateTime.utc_now(),
        socket.assigns.time_display.time_zone
      )

    socket =
      if feed_visible && viewer_visible && matches_category && matches_date do
        socket
        |> assign(:events_empty?, false)
        |> stream_insert(:events, event, at: 0)
      else
        socket
      end

    {:noreply, socket}
  end

  ## Private Helpers

  defp chip_label("all"), do: gettext("All")
  defp chip_label("media"), do: gettext("Media")
  defp chip_label("downloads"), do: gettext("Downloads")
  defp chip_label("search"), do: pgettext("search", "Search")
  defp chip_label("system"), do: gettext("System")
  defp chip_label("playback"), do: gettext("Playback")
  defp chip_label("plugin"), do: gettext("Plugins")
  defp chip_label("errors"), do: gettext("Errors")

  # The badge is only rendered for non-info severities.
  defp severity_label(:error), do: pgettext("severity", "error")
  defp severity_label(:warning), do: pgettext("severity", "warning")
  defp severity_label(other), do: to_string(other)

  defp filter_chips(user) do
    case Visibility.visible_categories(user) do
      :all -> @chips
      categories -> Enum.filter(@chips, &(&1.value == "all" or &1.value in categories))
    end
  end

  defp load_events(socket) do
    category_filter = socket.assigns.category_filter
    date_filter = socket.assigns.date_filter

    filter_opts =
      build_filter_opts(category_filter, date_filter, socket.assigns.time_display.time_zone)

    # Request one more than page_size to check if there are more results
    events =
      Events.list_visible_events(
        socket.assigns.current_user,
        filter_opts ++ [limit: @page_size + 1, offset: 0]
      )

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

    filter_opts =
      build_filter_opts(category_filter, date_filter, socket.assigns.time_display.time_zone)

    offset = page * @page_size

    # Request one more than page_size to check if there are more results
    events =
      Events.list_visible_events(
        socket.assigns.current_user,
        filter_opts ++ [limit: @page_size + 1, offset: offset]
      )

    has_more? = length(events) > @page_size
    events = Enum.take(events, @page_size)

    socket =
      Enum.reduce(events, socket, fn event, acc ->
        stream_insert(acc, :events, event)
      end)

    assign(socket, :has_more?, has_more?)
  end

  defp build_filter_opts(category_filter, date_filter, zone) do
    category_opts =
      case category_filter do
        "all" -> []
        "errors" -> [severity: :error]
        category -> [category: category]
      end

    date_opts = DateFilter.opts(date_filter, DateTime.utc_now(), zone)

    category_opts ++ date_opts ++ [exclude_types: Presentation.feed_hidden_types()]
  end

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
      :user -> gettext("User")
      :system -> gettext("System")
      :job -> format_job_name(event.actor_id)
      nil -> gettext("System")
      _ -> gettext("Unknown")
    end
  end

  defp format_job_name(nil), do: gettext("Job")
  defp format_job_name("movie_search"), do: gettext("Movie Search")
  defp format_job_name("tv_show_search"), do: gettext("TV Search")
  defp format_job_name("episode_search"), do: gettext("Episode Search")
  defp format_job_name("season_search"), do: gettext("Season Search")
  defp format_job_name("metadata_sync"), do: gettext("Metadata Sync")
  defp format_job_name("library_scan"), do: gettext("Library Scan")

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

  defp relative_time(datetime, display) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 ->
        gettext("just now")

      diff < 3600 ->
        ngettext("%{count} minute ago", "%{count} minutes ago", div(diff, 60))

      diff < 86400 ->
        ngettext("%{count} hour ago", "%{count} hours ago", div(diff, 3600))

      diff < 604_800 ->
        ngettext("%{count} day ago", "%{count} days ago", div(diff, 86400))

      true ->
        format(datetime, :date, display)
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
      |> Map.take(Presentation.simple_change_fields())
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

  # Delegates to Presentation.field_label/1, the single source of truth for
  # these labels, so this expanded breakdown cannot drift from the one-line
  # summary rendered by Presentation.detail/1 for the same event.
  defp humanize_field_name(field), do: Presentation.field_label(field)

  defp format_change_value("monitored", true), do: pgettext("monitoring", "monitored")
  defp format_change_value("monitored", false), do: pgettext("monitoring", "not monitored")
  defp format_change_value("monitor_new_seasons", "all"), do: gettext("all seasons")
  defp format_change_value("monitor_new_seasons", "none"), do: gettext("no seasons")
  defp format_change_value(_field, nil), do: gettext("none")
  defp format_change_value(_field, value), do: to_string(value)

  defp format_metadata_change_value("rating", nil), do: gettext("none")
  defp format_metadata_change_value("rating", value) when is_number(value), do: "#{value}/10"
  defp format_metadata_change_value("genres", nil), do: gettext("none")

  defp format_metadata_change_value("genres", count) when is_integer(count),
    do: ngettext("%{count} genre", "%{count} genres", count)

  defp format_metadata_change_value("cast", 0), do: gettext("none")

  defp format_metadata_change_value("cast", count) when is_integer(count),
    do: ngettext("%{count} member", "%{count} members", count)

  defp format_metadata_change_value("crew", 0), do: gettext("none")

  defp format_metadata_change_value("crew", count) when is_integer(count),
    do: ngettext("%{count} member", "%{count} members", count)

  defp format_metadata_change_value(_field, true), do: gettext("added")
  defp format_metadata_change_value(_field, nil), do: gettext("none")
  defp format_metadata_change_value(_field, value), do: to_string(value)

  defp format_filter_stat_label(key) do
    case key do
      "total_results" -> gettext("Total")
      "below_quality_threshold" -> gettext("Below quality")
      "no_valid_season_packs" -> gettext("No season packs")
      # New detailed rejection reasons
      "individual_episode" -> pgettext("tv", "Episode")
      "missing_season_marker" -> gettext("No season")
      # Hard removals only — size/seeders/ratio are penalties now, not rejections
      "blocked_tag" -> gettext("Blocked")
      "invalid" -> gettext("Invalid")
      "title_mismatch" -> gettext("Wrong title")
      "year_mismatch" -> gettext("Wrong year")
      _ -> String.replace(key, "_", " ") |> String.capitalize()
    end
  end

  defp format_breakdown_label(key) do
    case key do
      "quality" -> gettext("Quality")
      "seeders" -> gettext("Seeders")
      "size" -> gettext("Size")
      "age" -> gettext("Age")
      "tag_bonus" -> gettext("Tag bonus")
      "preferred_tags" -> gettext("Preferred")
      "blocked_tags" -> gettext("Blocked")
      "custom_format" -> gettext("Custom format")
      "custom_format_score" -> gettext("Custom format")
      "title_relevance" -> gettext("Title match")
      "title_match" -> gettext("Title match")
      # Soft-penalty contributions. size_penalty is no longer produced, but
      # search events recorded before size became a hard limit still carry it.
      "size_penalty" -> gettext("Size penalty")
      "seeder_penalty" -> gettext("Seeder penalty")
      "identity_penalty" -> gettext("Identity mismatch")
      "language_rank" -> gettext("Language rank")
      "language_matches" -> gettext("Language matches")
      "audio_languages" -> gettext("Audio")
      "audio_assumed" -> gettext("Audio assumed")
      _ -> String.replace(key, "_", " ") |> String.capitalize()
    end
  end

  defp format_breakdown_value(value) when is_list(value), do: Enum.join(value, "+")

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
