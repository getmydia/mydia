defmodule MydiaWeb.AdminDashboardLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias MydiaWeb.AdminDashboardLive.PlaysChartComponents

  import MydiaWeb.Formatters, only: [format_file_size: 1]

  attr :active_sessions, :list, required: true
  attr :background_jobs, :list, required: true
  attr :recent_activity, :list, required: true
  attr :last_play_at, :any, default: nil
  attr :plays_today, :integer, required: true
  attr :plays_yesterday, :integer, required: true
  attr :plays_week, :integer, required: true
  attr :plays_prior_week, :integer, required: true
  attr :days, :list, required: true
  attr :range_days, :integer, required: true

  def dashboard_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <.kpi_row
        active_streams={length(@active_sessions)}
        plays_today={@plays_today}
        plays_yesterday={@plays_yesterday}
        plays_week={@plays_week}
        plays_prior_week={@plays_prior_week}
        idle_for={@last_play_at && elapsed_label(@last_play_at)}
      />

      <.dash_section
        id="now-playing"
        title="Now Playing"
        icon="hero-play-circle"
        empty?={@active_sessions == []}
        empty_text={now_playing_idle_text(@last_play_at)}
      >
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <.now_playing_card :for={session <- @active_sessions} session={session} />
        </div>
      </.dash_section>

      <%!--
      Background transcodes only, never playback. Sessions already appear above
      as now-playing cards, and both session types also insert a TranscodeJob
      row, so listing every active job here would show each viewer twice.
      --%>
      <.admin_section
        :if={@background_jobs != []}
        id="background-transcodes"
        title="Background transcodes"
        icon="hero-cog-6-tooth"
        count={length(@background_jobs)}
      >
        <.admin_list id="background-transcodes-list" items={@background_jobs}>
          <:row :let={job}>
            <.admin_row id={"transcode-job-#{job.id}"}>
              <:title>{transcode_job_title(job)}</:title>
              <:descriptor>
                {job_type_label(job.type)}<span :if={job.file_size}> · {format_file_size(
                  job.file_size
                )}</span>
              </:descriptor>
              <:badges>
                <span class="badge badge-sm badge-outline">{job.status}</span>
              </:badges>
              <:actions>
                <.row_actions>
                  <.row_action
                    icon="hero-x-mark"
                    title="Cancel transcode"
                    destructive
                    phx-click="cancel_transcode_job"
                    phx-value-id={job.id}
                  />
                </.row_actions>
              </:actions>
            </.admin_row>
          </:row>
          <:empty>No background transcodes.</:empty>
        </.admin_list>
      </.admin_section>

      <PlaysChartComponents.plays_chart days={@days} range={@range_days} />

      <.dash_section
        id="recent-activity"
        title="Recent Activity"
        icon="hero-clock"
        empty?={@recent_activity == []}
        empty_text="Nothing has happened yet."
      >
        <div class="bg-base-200 rounded-box divide-y divide-base-300">
          <%= for item <- @recent_activity do %>
            <%= if item.type == :transcode_job do %>
              <.recent_job_card job={item.data} />
            <% else %>
              <.recent_watch_card progress={item.data} />
            <% end %>
          <% end %>
        </div>
      </.dash_section>
    </div>
    """
  end

  defp job_type_label("direct"), do: "Direct"
  defp job_type_label("stream"), do: "Stream"
  defp job_type_label(_download), do: "Download"

  # `recent_plays/1` reads playback.started events, so this is when a play
  # began. There is no durable session-end record, and claiming a stream
  # "ended" would be a lie the data cannot support.
  defp now_playing_idle_text(nil), do: "Nobody is watching."

  defp now_playing_idle_text(at) do
    "Nobody is watching. Last played #{elapsed_label(at)} ago."
  end

  attr :active_streams, :integer, required: true
  attr :plays_today, :integer, required: true
  attr :plays_week, :integer, required: true
  attr :plays_yesterday, :integer, required: true
  attr :plays_prior_week, :integer, required: true
  attr :idle_for, :string, default: nil

  def kpi_row(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
      <div id="kpi-active-streams" class="stat bg-base-200 rounded-box shadow-sm">
        <div class="stat-title">Active streams</div>
        <div class="stat-value text-2xl">{@active_streams}</div>
        <div :if={@active_streams == 0 and @idle_for} class="stat-desc">Idle for {@idle_for}</div>
      </div>
      <div id="kpi-plays-today" class="stat bg-base-200 rounded-box shadow-sm">
        <div class="stat-title">Plays today</div>
        <div class="stat-value text-2xl">{@plays_today}</div>
        <div :if={@plays_today > 0 or @plays_yesterday > 0} class="stat-desc">
          {@plays_yesterday} yesterday
        </div>
      </div>
      <div id="kpi-plays-week" class="stat bg-base-200 rounded-box shadow-sm">
        <div class="stat-title">Plays this week</div>
        <div class="stat-value text-2xl">{@plays_week}</div>
        <div :if={@plays_week > 0 or @plays_prior_week > 0} class="stat-desc">
          {@plays_prior_week} the week before
        </div>
      </div>
    </div>
    """
  end

  @doc """
  A dashboard section that collapses to a single line when it has nothing to
  show, rather than reserving a placeholder box.

  `empty_text` is only read when `empty?` is true, so a section that can never
  be empty passes neither.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :empty?, :boolean, default: false
  attr :empty_text, :string, default: nil
  slot :inner_block, required: true

  def dash_section(assigns) do
    ~H"""
    <.admin_section id={@id} title={@title} icon={@icon}>
      <p
        :if={@empty?}
        id={"#{@id}-idle"}
        class="flex items-center gap-2 text-sm text-base-content/50"
      >
        <.icon name={@icon} class="w-4 h-4 opacity-40" />{@empty_text}
      </p>
      <div :if={!@empty?}>{render_slot(@inner_block)}</div>
    </.admin_section>
    """
  end

  @doc """
  A bare duration such as "3h" or "2d".

  Separate from `relative_time/1` because the callers here read "Last played
  3h ago" and "Idle for 3h", and the second must not carry the suffix.
  """
  @spec elapsed_label(DateTime.t()) :: String.t()
  def elapsed_label(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "under a minute"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3600)}h"
      true -> "#{div(diff, 86_400)}d"
    end
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
      class="bg-base-200 rounded-box p-3 space-y-2"
    >
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
    """
  end

  attr :job, :map, required: true

  def recent_job_card(assigns) do
    {status_icon, status_text, status_badge} = job_status_tone(assigns.job.status)

    assigns =
      assigns
      |> assign(:title, transcode_job_title(assigns.job))
      |> assign(:status_icon, status_icon)
      |> assign(:status_text, status_text)
      |> assign(:status_badge, status_badge)
      |> assign(:action_label, job_action_label(assigns.job.status))

    ~H"""
    <div class="p-3 flex items-center gap-3 hover:bg-base-200/50 transition-colors">
      <div class={[
        "flex-shrink-0 w-6 h-6 flex items-center justify-center rounded-full",
        @status_text
      ]}>
        <.icon name={@status_icon} class="w-5 h-5" />
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
          <span class={["badge badge-xs", @status_badge]}>
            {@job.status}
          </span>
          <%= if @job.file_size do %>
            <span class="font-mono">{format_file_size(@job.file_size)}</span>
          <% end %>
        </div>
      </div>
      <div class="flex items-center gap-1">
        <span class="text-xs opacity-40 whitespace-nowrap">
          {relative_time(@job.updated_at)}
        </span>
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-square text-error"
          title={@action_label}
          aria-label={@action_label}
          phx-click="cancel_transcode_job"
          phx-value-id={@job.id}
          data-confirm={if @job.status == "ready", do: "Delete this file?", else: nil}
        >
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  # A finished row's button deletes the file; only a live job is cancelled.
  defp job_action_label(status) when status in ["ready", "failed"], do: "Delete"
  defp job_action_label(_in_progress), do: "Cancel transcode"

  defp job_status_tone("ready"), do: {"hero-check-circle", "text-success", "badge-success"}
  defp job_status_tone("failed"), do: {"hero-x-circle", "text-error", "badge-error"}
  defp job_status_tone(_in_progress), do: {"hero-arrow-path", "text-info", "badge-info"}

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

  defp build_image_url(path) when is_binary(path), do: ImageUrl.image_url(path, "w92")
  defp build_image_url(_), do: nil

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
