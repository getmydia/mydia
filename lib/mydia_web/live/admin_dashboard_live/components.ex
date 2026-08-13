defmodule MydiaWeb.AdminDashboardLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Streaming.SessionSampler.Sample
  alias MydiaWeb.AdminDashboardLive.ChartGeometry

  @series_fills ~w(fill-primary fill-secondary fill-accent fill-info fill-success fill-warning)
  @max_series length(@series_fills)
  @chart_w 600
  @chart_h 160
  @stack_gap 2

  @doc """
  Stable fill class for a session key. Public so the recolor regression test can
  assert the same class appears before and after another session ends.
  """
  def series_fill(key), do: Enum.at(@series_fills, :erlang.phash2(key, length(@series_fills)))

  defp series_swatch(key), do: String.replace_prefix(series_fill(key), "fill-", "bg-")

  attr :active_streams, :integer, required: true
  attr :total_mbps, :float, required: true
  attr :plays_today, :integer, required: true
  attr :plays_week, :integer, required: true
  attr :unmeasured_count, :integer, required: true

  def kpi_row(assigns) do
    ~H"""
    <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
      <div id="kpi-active-streams" class="stat bg-base-200 rounded-box shadow-sm">
        <div class="stat-title">Active streams</div>
        <div class="stat-value text-2xl">{@active_streams}</div>
      </div>
      <div id="kpi-bandwidth" class="stat bg-base-200 rounded-box shadow-sm">
        <div class="stat-title">Bandwidth</div>
        <div class="stat-value text-2xl">
          {format_mbps(@total_mbps)}<span class="text-sm font-normal opacity-60 ml-1">Mbps</span>
        </div>
        <div class="stat-desc">
          Estimated{if @unmeasured_count > 0, do: ", #{@unmeasured_count} unmeasured", else: ""}
        </div>
      </div>
      <div id="kpi-plays-today" class="stat bg-base-200 rounded-box shadow-sm">
        <div class="stat-title">Plays today</div>
        <div class="stat-value text-2xl">{@plays_today}</div>
      </div>
      <div id="kpi-plays-week" class="stat bg-base-200 rounded-box shadow-sm">
        <div class="stat-title">Plays this week</div>
        <div class="stat-value text-2xl">{@plays_week}</div>
      </div>
    </div>
    """
  end

  attr :samples, :list, required: true
  attr :unmeasured_count, :integer, required: true

  def bandwidth_chart(assigns) do
    samples = fold_other_sessions(assigns.samples)
    bands = ChartGeometry.stacked_bands(samples, @chart_w, @chart_h)
    count = length(samples)
    step = if count > 1, do: @chart_w / (count - 1), else: 0.0

    assigns =
      assigns
      |> assign(:bands, bands)
      |> assign(:samples, samples)
      |> assign(:step, step)
      |> assign(:show_legend?, length(bands) >= 2)
      |> assign(:chart_w, @chart_w)
      |> assign(:chart_h, @chart_h)

    ~H"""
    <div class="space-y-2">
      <div class="flex items-baseline justify-between gap-2">
        <h3 class="font-semibold text-base-content">Estimated bandwidth</h3>
        <%= if @unmeasured_count > 0 do %>
          <p class="text-xs opacity-60">
            {@unmeasured_count} unmeasured
          </p>
        <% end %>
      </div>
      <%= if @bands == [] do %>
        <div
          id="bandwidth-chart-empty"
          class="flex items-center justify-center h-40 text-sm opacity-60"
        >
          Collecting samples
        </div>
      <% else %>
        <div id="bandwidth-chart">
          <svg
            viewBox={"0 0 #{@chart_w} #{@chart_h}"}
            preserveAspectRatio="none"
            class="w-full h-40"
          >
            <%= for band <- @bands do %>
              <path
                d={band.path}
                class={[series_fill(band.key), "stroke-base-100"]}
                stroke-width="2"
                fill-opacity="0.85"
              />
            <% end %>
            <%= for {sample, index} <- Enum.with_index(@samples) do %>
              <rect
                x={Float.round(index * @step - @step / 2, 2)}
                y="0"
                width={Float.round(@step, 2)}
                height={@chart_h}
                fill="transparent"
              >
                <title>
                  {Calendar.strftime(sample.at, "%H:%M:%S")}: {format_mbps(sample_total(sample))} Mbps
                </title>
              </rect>
            <% end %>
          </svg>
          <%= if @show_legend? do %>
            <div id="bandwidth-chart-legend" class="flex flex-wrap gap-3 mt-2">
              <%= for band <- @bands do %>
                <div class="flex items-center gap-1.5 text-xs text-base-content">
                  <span class={["inline-block w-2.5 h-2.5 rounded-sm", series_swatch(band.key)]}></span>
                  <span class="opacity-60 truncate max-w-[10rem]">{band.key}</span>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :days, :list, required: true

  def plays_chart(assigns) do
    total = Enum.reduce(assigns.days, 0, fn d, acc -> acc + d.movies + d.episodes end)
    columns = ChartGeometry.bar_columns(assigns.days, @chart_w, @chart_h)

    assigns =
      assigns
      |> assign(:empty?, total == 0)
      |> assign(:columns, columns)
      |> assign(:chart_w, @chart_w)
      |> assign(:chart_h, @chart_h)
      |> assign(:stack_gap, @stack_gap)

    ~H"""
    <div class="space-y-2">
      <h3 class="font-semibold text-base-content">Plays</h3>
      <%= if @empty? do %>
        <div id="plays-chart-empty" class="flex items-center justify-center h-40 text-sm opacity-60">
          No plays in this window
        </div>
      <% else %>
        <div id="plays-chart">
          <svg viewBox={"0 0 #{@chart_w} #{@chart_h}"} class="w-full h-40">
            <%= for col <- @columns do %>
              <% gap = if col.episodes.height > 0 and col.movies.height > 0, do: @stack_gap, else: 0 %>
              <%= if col.episodes.height > 0 do %>
                <rect
                  x={col.x}
                  y={col.episodes.y}
                  width={col.width}
                  height={max(col.episodes.height - gap / 2, 0)}
                  class="fill-primary"
                />
              <% end %>
              <%= if col.movies.height > 0 do %>
                <rect
                  x={col.x}
                  y={col.movies.y + gap / 2}
                  width={col.width}
                  height={max(col.movies.height - gap / 2, 0)}
                  class="fill-secondary"
                />
              <% end %>
              <rect x={col.x} y="0" width={col.width} height={@chart_h} fill="transparent">
                <title>
                  {col.label}: {col.movies.count} movies, {col.episodes.count} episodes
                </title>
              </rect>
            <% end %>
          </svg>
          <div id="plays-chart-legend" class="flex flex-wrap gap-3 mt-2">
            <div class="flex items-center gap-1.5 text-xs text-base-content">
              <span class="inline-block w-2.5 h-2.5 rounded-sm bg-primary"></span>
              <span class="opacity-60">Episodes</span>
            </div>
            <div class="flex items-center gap-1.5 text-xs text-base-content">
              <span class="inline-block w-2.5 h-2.5 rounded-sm bg-secondary"></span>
              <span class="opacity-60">Movies</span>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :session, :map, required: true

  def now_playing_card(assigns) do
    session = assigns.session

    progress_pct =
      case {session.position_seconds, session.duration_seconds} do
        {pos, dur} when is_number(pos) and is_number(dur) and dur > 0 ->
          min(pos / dur * 100, 100)

        _ ->
          nil
      end

    mbps =
      case session.bitrate_bps do
        bps when is_integer(bps) and bps > 0 -> Float.round(bps / 1_000_000, 2)
        _ -> nil
      end

    assigns =
      assigns
      |> assign(:username, user_label(session.user))
      |> assign(:progress_pct, progress_pct)
      |> assign(:mbps, mbps)
      |> assign(
        :mode_label,
        if(session.mode == :transcode, do: "Transcode", else: "Direct Play")
      )

    ~H"""
    <div
      id={"now-playing-#{@session.media_file_id}"}
      class="card bg-base-100 shadow-sm border border-base-300"
    >
      <div class="card-body p-3 gap-2">
        <div class="flex items-center gap-3">
          <%= if @session.poster_path do %>
            <div class="avatar">
              <div class="w-10 rounded">
                <img src={build_image_url(@session.poster_path)} alt="Poster" />
              </div>
            </div>
          <% else %>
            <div class="avatar placeholder">
              <div class="bg-neutral text-neutral-content rounded-full w-10">
                <span class="text-sm uppercase">
                  {String.slice(@username, 0, 2)}
                </span>
              </div>
            </div>
          <% end %>
          <div class="flex-1 min-w-0">
            <div class="font-medium text-sm truncate" title={@session.media_title}>
              {@session.media_title}
            </div>
            <div class="text-xs opacity-60 truncate">
              {@session.episode_info || "Movie"}
            </div>
            <div class="text-xs opacity-60 truncate">{@username}</div>
          </div>
          <div class="flex flex-col items-end gap-1">
            <span class={[
              "badge badge-xs badge-outline",
              if(@session.mode == :transcode, do: "badge-warning", else: "badge-success")
            ]}>
              {@mode_label}
            </span>
            <%= if @mbps do %>
              <span class="text-xs font-mono opacity-60">{format_mbps(@mbps)} Mbps</span>
            <% end %>
          </div>
        </div>
        <%= if @progress_pct do %>
          <progress
            class="progress progress-primary w-full h-1"
            value={@progress_pct}
            max="100"
          ></progress>
          <div class="flex justify-between text-xs font-mono opacity-60">
            <span>{format_clock(@session.position_seconds)}</span>
            <span>{format_clock(@session.duration_seconds)}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :job, :map, required: true

  def recent_job_card(assigns) do
    assigns = assign(assigns, :title, transcode_job_title(assigns.job))

    ~H"""
    <div class="p-3 flex items-center gap-3 hover:bg-base-200/50 transition-colors">
      <div class={[
        "flex-shrink-0 w-6 h-6 flex items-center justify-center rounded-full",
        if(@job.status == "ready", do: "text-success", else: "text-error")
      ]}>
        <.icon
          name={if(@job.status == "ready", do: "hero-check-circle", else: "hero-x-circle")}
          class="w-5 h-5"
        />
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-sm font-medium truncate" title={@title}>{@title}</div>
        <div class="text-xs opacity-50 flex items-center gap-1">
          <%= cond do %>
            <% @job.type == "direct" -> %>
              <span class="badge badge-xs badge-success">Direct</span>
            <% @job.type == "stream" -> %>
              <span class="badge badge-xs badge-info">Stream</span>
            <% true -> %>
              <span class="badge badge-xs badge-ghost">DL</span>
          <% end %>
          <span class={[
            "badge badge-xs",
            if(@job.status == "ready", do: "badge-success", else: "badge-error")
          ]}>
            {@job.status}
          </span>
          <%= if @job.file_size do %>
            <span class="font-mono">{format_size(@job.file_size)}</span>
          <% end %>
        </div>
      </div>
      <div class="flex items-center gap-1">
        <span class="text-xs opacity-40 whitespace-nowrap">
          {relative_time(@job.updated_at)}
        </span>
        <button
          class="btn btn-ghost btn-xs btn-square text-error"
          phx-click="delete_transcode_job"
          phx-value-id={@job.id}
          data-confirm={if @job.status == "ready", do: "Delete this file?", else: nil}
        >
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  attr :progress, :map, required: true

  def recent_watch_card(assigns) do
    poster_path = Mydia.Playback.progress_poster_path(assigns.progress)
    title = Mydia.Playback.progress_title(assigns.progress)
    user = assigns.progress.user

    assigns =
      assigns
      |> assign(:poster_path, poster_path)
      |> assign(:title, title)
      |> assign(:username, user_label(user))
      |> assign(:avatar_url, user && user.avatar_url)

    ~H"""
    <div class="p-3 flex items-center gap-3 hover:bg-base-200/50 transition-colors">
      <%= if @poster_path do %>
        <div class="avatar">
          <div class="w-8 rounded">
            <img src={build_image_url(@poster_path)} alt="Poster" />
          </div>
        </div>
      <% else %>
        <div class="avatar placeholder">
          <div class="bg-base-300 text-base-content rounded-full w-8">
            <span class="text-xs">
              {@username |> String.slice(0, 1) |> String.upcase()}
            </span>
          </div>
        </div>
      <% end %>
      <div class="flex-1 min-w-0">
        <div class="text-sm font-medium truncate" title={@title}>{@title}</div>
        <div class="text-xs opacity-50 flex items-center gap-1">
          <%= if @avatar_url do %>
            <div class="avatar">
              <div class="w-4 rounded-full">
                <img src={@avatar_url} alt={@username} />
              </div>
            </div>
          <% end %>
          <span>{@username}</span>
        </div>
      </div>
      <div class="text-xs opacity-40 whitespace-nowrap">
        {relative_time(@progress.last_watched_at)}
      </div>
    </div>
    """
  end

  defp fold_other_sessions(samples) when length(samples) < 2, do: samples

  defp fold_other_sessions(samples) do
    keys =
      samples
      |> Enum.flat_map(&Map.keys(&1.sessions))
      |> Enum.uniq()
      |> Enum.sort()

    if length(keys) <= @max_series do
      samples
    else
      {kept, overflow} = Enum.split(keys, @max_series - 1)
      kept_set = MapSet.new(kept)

      Enum.map(samples, fn %Sample{} = sample ->
        {kept_sessions, other_total} =
          Enum.reduce(sample.sessions, {%{}, 0.0}, fn {key, value}, {acc, other} ->
            if MapSet.member?(kept_set, key) do
              {Map.put(acc, key, value), other}
            else
              {acc, other + value}
            end
          end)

        sessions =
          if other_total > 0 or overflow != [] do
            # Always expose Other when we folded keys, so the band persists even
            # at samples where overflow sessions contributed zero.
            Map.put(kept_sessions, "Other", other_total)
          else
            kept_sessions
          end

        %{sample | sessions: sessions}
      end)
    end
  end

  defp sample_total(%Sample{sessions: sessions}), do: sessions |> Map.values() |> Enum.sum()

  defp format_mbps(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp format_mbps(n) when is_integer(n), do: Integer.to_string(n)
  defp format_mbps(_), do: "0.0"

  defp format_clock(nil), do: "--:--"

  defp format_clock(seconds) when is_number(seconds) do
    total = trunc(seconds)
    h = div(total, 3600)
    m = div(rem(total, 3600), 60)
    s = rem(total, 60)

    if h > 0 do
      "#{h}:#{pad2(m)}:#{pad2(s)}"
    else
      "#{m}:#{pad2(s)}"
    end
  end

  defp pad2(n), do: String.pad_leading("#{n}", 2, "0")

  defp transcode_job_title(job) do
    cond do
      job.media_file.episode && job.media_file.episode.media_item ->
        ep = job.media_file.episode
        s = String.pad_leading("#{ep.season_number}", 2, "0")
        e = String.pad_leading("#{ep.episode_number}", 2, "0")
        "#{ep.media_item.title} - S#{s}E#{e}"

      job.media_file.media_item ->
        job.media_file.media_item.title

      true ->
        path = job.media_file.relative_path || job.media_file.path
        if path, do: Path.basename(path), else: "Unknown"
    end
  end

  defp user_label(nil), do: "Unknown"
  defp user_label(%{username: username}) when is_binary(username) and username != "", do: username
  defp user_label(%{email: email}) when is_binary(email) and email != "", do: email
  defp user_label(_), do: "Unknown"

  defp build_image_url(nil), do: nil
  defp build_image_url(path) when is_binary(path), do: ImageUrl.image_url(path, "w92")
  defp build_image_url(_), do: nil

  defp format_size(nil), do: "-"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_size(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"

  defp format_size(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 1)} GB"

  defp relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end
end
