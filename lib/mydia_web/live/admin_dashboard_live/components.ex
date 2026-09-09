defmodule MydiaWeb.AdminDashboardLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias MydiaWeb.AdminDashboardLive.ChartGeometry

  @chart_w 600
  @chart_h 160
  @stack_gap 2

  # @chart_w / @chart_h are the PLOT box. Padding is added around it in the
  # viewBox so tick labels have somewhere to live without being clipped.
  @pad_l 28
  @pad_t 8
  @pad_b 24

  attr :active_streams, :integer, required: true
  attr :plays_today, :integer, required: true
  attr :plays_week, :integer, required: true

  def kpi_row(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
      <div id="kpi-active-streams" class="stat bg-base-200 rounded-box shadow-sm">
        <div class="stat-title">Active streams</div>
        <div class="stat-value text-2xl">{@active_streams}</div>
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

  attr :days, :list, required: true

  def plays_chart(assigns) do
    assigns =
      assigns
      |> assign(:columns, ChartGeometry.bar_columns(assigns.days, @chart_w, @chart_h))
      |> assign(:y_ticks, ChartGeometry.y_ticks(assigns.days, @chart_h))
      |> assign(:x_ticks, ChartGeometry.x_ticks(assigns.days, @chart_w))
      |> assign(:chart_w, @chart_w)
      |> assign(:chart_h, @chart_h)
      |> assign(:stack_gap, @stack_gap)
      |> assign(:pad_l, @pad_l)
      |> assign(:pad_t, @pad_t)
      |> assign(:view_w, @chart_w + @pad_l)
      |> assign(:view_h, @chart_h + @pad_t + @pad_b)

    ~H"""
    <div class="space-y-2">
      <h3 class="font-semibold text-base-content">Plays</h3>
      <div id="plays-chart">
        <svg viewBox={"0 0 #{@view_w} #{@view_h}"} class="w-full h-48">
          <g transform={"translate(#{@pad_l}, #{@pad_t})"}>
            <line
              :for={tick <- @y_ticks}
              x1="0"
              y1={tick.y}
              x2={@chart_w}
              y2={tick.y}
              class="stroke-base-300"
              stroke-width="1"
            />
            <text
              :for={tick <- @y_ticks}
              x="-6"
              y={tick.y + 3}
              text-anchor="end"
              font-size="9"
              class="fill-base-content/60"
              phx-no-format
            >{tick.value}</text>
            <%= for col <- @columns do %>
              <% gap = if col.episodes.height > 0 and col.movies.height > 0, do: @stack_gap, else: 0 %>
              <rect
                :if={col.episodes.height > 0}
                x={col.x}
                y={col.episodes.y}
                width={col.width}
                height={max(col.episodes.height - gap / 2, 0)}
                class="fill-primary"
              />
              <rect
                :if={col.movies.height > 0}
                x={col.x}
                y={col.movies.y + gap / 2}
                width={col.width}
                height={max(col.movies.height - gap / 2, 0)}
                class="fill-secondary"
              />
              <rect x={col.x} y="0" width={col.width} height={@chart_h} fill="transparent">
                <title>
                  {col.label}: {col.movies.count} movies, {col.episodes.count} episodes
                </title>
              </rect>
            <% end %>
            <text
              :for={tick <- @x_ticks}
              x={tick.x}
              y={@chart_h + 16}
              text-anchor="middle"
              font-size="9"
              class="fill-base-content/60"
            >
              {tick.label}
            </text>
          </g>
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
      |> assign(:mode_label, mode_label(session.plan))
      |> assign(:mode_class, mode_class(session.plan))
      |> assign(:video_line, video_line(session.plan))
      |> assign(:resolution_line, resolution_line(session.plan))
      |> assign(:audio_line, audio_line(session.plan))

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
            <span class={["badge badge-xs badge-outline", @mode_class]}>
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
        <div
          :if={@video_line || @resolution_line || @audio_line}
          class="text-xs font-mono opacity-60 space-y-0.5"
        >
          <div :if={@video_line} id={"now-playing-video-#{@session.media_file_id}"}>
            <span class="opacity-60">Video</span> {@video_line}
          </div>
          <div :if={@resolution_line} id={"now-playing-resolution-#{@session.media_file_id}"}>
            <span class="opacity-60">Res</span> {@resolution_line}
          </div>
          <div :if={@audio_line} id={"now-playing-audio-#{@session.media_file_id}"}>
            <span class="opacity-60">Audio</span> {@audio_line}
          </div>
        </div>
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

  # The badge follows the VIDEO action, not "either stream encodes". A
  # video-copy stream that converts audio is a remux, and calling that a
  # transcode would have an operator hunting for CPU load that is not there.
  defp mode_label(nil), do: "Direct Play"
  defp mode_label(%{video: %{action: :copy}}), do: "Remux"
  defp mode_label(_plan), do: "Transcode"

  defp mode_class(nil), do: "badge-success"
  defp mode_class(%{video: %{action: :copy}}), do: "badge-info"
  defp mode_class(_plan), do: "badge-warning"

  defp video_line(nil), do: nil

  defp video_line(%{video: %{action: :copy, from_codec: codec}}) when is_binary(codec) do
    "#{codec} (copy)"
  end

  defp video_line(%{video: %{action: :encode} = video}) do
    tier = tier_label(video.tier)
    base = "#{video.from_codec || "unknown"} -> #{video.to_codec}"
    if tier, do: "#{base} (#{tier})", else: base
  end

  defp video_line(_plan), do: nil

  defp tier_label(:full_hardware), do: "VAAPI"
  defp tier_label(:hybrid), do: "hybrid"
  defp tier_label(:software), do: "software"
  defp tier_label(_other), do: nil

  # Omitted rather than guessed when the source dimensions are unknown, which
  # is roughly 2% of the production library.
  defp resolution_line(%{video: %{from_width: fw, from_height: fh, to_width: tw, to_height: th}})
       when is_integer(fw) and is_integer(fh) and is_integer(tw) and is_integer(th) do
    if {fw, fh} == {tw, th} do
      "#{fw}x#{fh}"
    else
      "#{fw}x#{fh} -> #{tw}x#{th}"
    end
  end

  defp resolution_line(_plan), do: nil

  defp audio_line(nil), do: nil

  defp audio_line(%{audio: %{action: action, from_codec: from, to_codec: to} = audio}) do
    codecs = if action == :copy, do: "#{from} (copy)", else: "#{from || "unknown"} -> #{to}"
    if audio.language, do: "#{codecs} - #{audio.language}", else: codecs
  end

  defp audio_line(_plan), do: nil

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
