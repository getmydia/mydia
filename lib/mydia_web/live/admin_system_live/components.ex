defmodule MydiaWeb.AdminSystemLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  # ============================================================================
  # Tab Components
  # ============================================================================

  attr :system_info, :map, required: true
  attr :database_info, :map, required: true
  attr :library_paths_count, :integer, required: true
  attr :download_clients_count, :integer, required: true
  attr :indexers_count, :integer, required: true
  attr :stuck_upgrades, :integer, required: true
  attr :active_sessions, :list, required: true
  attr :active_jobs, :list, required: true
  attr :recent_activity, :list, required: true

  def status_tab(assigns) do
    ~H"""
    <div class="space-y-6 sm:space-y-8 p-4 sm:p-6">
      <%!--
      Stuck upgrades. Only rendered when there is something wrong: a zero here
      is the normal state and would be pure noise on every visit.
      --%>
      <%= if @stuck_upgrades > 0 do %>
        <div id="stuck-upgrades-alert" class="alert alert-warning shadow-sm">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <div class="flex-1">
            <div class="font-medium">
              {@stuck_upgrades} {if @stuck_upgrades == 1,
                do: "file is",
                else: "files are"} stuck mid-upgrade
            </div>
            <div class="text-sm opacity-80">
              Each one is holding its replacement and the copy it was meant to replace, so that
              disk space stays spoken for until the upgrade finishes. This happens when the
              finalize step never ran or failed after import. Look for failed
              <span class="font-mono">UpgradeFinalize</span>
              jobs.
            </div>
          </div>
          <.link navigate={~p"/admin/jobs"} class="btn btn-sm">View jobs</.link>
        </div>
      <% end %>

      <%!-- Top Row: System Info + Database --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 sm:gap-8">
        <%!-- System Information --%>
        <div>
          <h3 class="text-lg font-semibold flex items-center gap-2 mb-3 sm:mb-4">
            <.icon name="hero-server" class="w-5 h-5 text-primary" /> System
          </h3>
          <div class="grid grid-cols-2 gap-2 sm:gap-4">
            <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
              <div class="stat-title text-xs sm:text-sm">Version</div>
              <div class="stat-value text-base sm:text-xl">
                <.link navigate={~p"/changelog"} class="link link-hover">
                  {@system_info.app_version}
                </.link>
                <%= if @system_info.dev_mode do %>
                  <span class="badge badge-warning badge-xs sm:badge-sm ml-1">dev</span>
                <% end %>
              </div>
            </div>
            <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
              <div class="stat-title text-xs sm:text-sm">Elixir</div>
              <div class="stat-value text-base sm:text-xl">{@system_info.elixir_version}</div>
            </div>
            <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
              <div class="stat-title text-xs sm:text-sm">Memory</div>
              <div class="stat-value text-base sm:text-xl">{@system_info.memory_used}</div>
            </div>
            <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
              <div class="stat-title text-xs sm:text-sm">Uptime</div>
              <div class="stat-value text-base sm:text-xl">{@system_info.uptime}</div>
            </div>
          </div>
        </div>

        <%!-- Database Information --%>
        <div>
          <h3 class="text-lg font-semibold flex items-center gap-2 mb-3 sm:mb-4 flex-wrap">
            <.icon name="hero-circle-stack" class="w-5 h-5 text-primary" /> Database
            <span class={"badge badge-sm sm:badge-md #{health_badge(@database_info.health)}"}>
              {if @database_info.health == :healthy, do: "Healthy", else: "Unhealthy"}
            </span>
          </h3>
          <div class="space-y-2 sm:space-y-3 bg-base-200 rounded-lg p-3 sm:p-5">
            <%= if @database_info.adapter == :postgres do %>
              <div class="flex justify-between items-center gap-2">
                <span class="text-base-content/70 text-sm">Adapter</span>
                <span class="badge badge-info badge-sm">PostgreSQL</span>
              </div>
              <div class="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-1 sm:gap-2">
                <span class="text-base-content/70 text-sm">Host</span>
                <code class="text-xs sm:text-sm bg-base-300 px-2 py-1 rounded truncate">
                  {@database_info.hostname}:{@database_info.port}
                </code>
              </div>
              <div class="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-1 sm:gap-2">
                <span class="text-base-content/70 text-sm">Database</span>
                <code class="text-xs sm:text-sm bg-base-300 px-2 py-1 rounded truncate">
                  {@database_info.database}
                </code>
              </div>
              <div class="flex justify-between items-center gap-2">
                <span class="text-base-content/70 text-sm">Size</span>
                <span class="font-medium text-sm">{@database_info.size}</span>
              </div>
            <% else %>
              <div class="flex justify-between items-center gap-2">
                <span class="text-base-content/70 text-sm">Adapter</span>
                <span class="badge badge-info badge-sm">SQLite</span>
              </div>
              <div class="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-1 sm:gap-2">
                <span class="text-base-content/70 text-sm">Location</span>
                <code class="text-xs sm:text-sm bg-base-300 px-2 py-1 rounded truncate max-w-full sm:max-w-[250px]">
                  {@database_info.path}
                </code>
              </div>
              <div class="flex justify-between items-center gap-2">
                <span class="text-base-content/70 text-sm">Size</span>
                <span class="font-medium text-sm">{@database_info.size}</span>
              </div>
              <div class="flex justify-between items-center gap-2">
                <span class="text-base-content/70 text-sm">Exists</span>
                <span class={[
                  "badge badge-sm",
                  if(@database_info.exists, do: "badge-success", else: "badge-error")
                ]}>
                  {if @database_info.exists, do: "Yes", else: "No"}
                </span>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <div class="divider"></div>

      <%!-- Bottom Row: Configuration Summary --%>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-6 sm:gap-8">
        <div class="stat p-4 bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <.icon name="hero-folder" class="w-8 h-8" />
          </div>
          <div class="stat-title">Library Paths</div>
          <div class="stat-value text-xl">{@library_paths_count}</div>
          <div class="stat-desc">
            <%= if @library_paths_count == 0 do %>
              No paths configured
            <% else %>
              Configured
            <% end %>
          </div>
        </div>

        <div class="stat p-4 bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <.icon name="hero-arrow-down-tray" class="w-8 h-8" />
          </div>
          <div class="stat-title">Download Clients</div>
          <div class="stat-value text-xl">{@download_clients_count}</div>
          <div class="stat-desc">
            <%= if @download_clients_count == 0 do %>
              No clients configured
            <% else %>
              Configured
            <% end %>
          </div>
        </div>

        <div class="stat p-4 bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <.icon name="hero-magnifying-glass" class="w-8 h-8" />
          </div>
          <div class="stat-title">Indexers</div>
          <div class="stat-value text-xl">{@indexers_count}</div>
          <div class="stat-desc">
            <%= if @indexers_count == 0 do %>
              No indexers configured
            <% else %>
              Configured
            <% end %>
          </div>
        </div>
      </div>

      <div class="divider">Activity</div>

      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6 sm:gap-8">
        <%!-- Panel 1: Active --%>
        <div class="bg-base-200 rounded-box p-4 h-full flex flex-col">
          <div class="flex items-center justify-between mb-4">
            <h3 class="font-semibold flex items-center gap-2">
              <.icon name="hero-bolt" class="w-5 h-5 text-primary" /> Active
            </h3>
            <span class="badge badge-sm badge-ghost">
              {length(@active_sessions) + length(@active_jobs)}
            </span>
          </div>

          <% active_items =
            Enum.map(@active_sessions, fn s -> {:session, s} end) ++
              Enum.map(@active_jobs, fn j -> {:job, j} end)

          capped_items = Enum.take(active_items, 20) %>
          <%= if capped_items == [] do %>
            <div class="flex-1 flex flex-col items-center justify-center p-8 text-base-content/50">
              <.icon name="hero-bolt" class="w-12 h-12 mb-2 opacity-20" />
              <span class="text-sm">Nothing active right now</span>
            </div>
          <% else %>
            <div class="overflow-y-auto max-h-[500px] pr-1 -mr-1">
              <div class="space-y-2">
                <%= for item <- capped_items do %>
                  <%= case item do %>
                    <% {:session, session} -> %>
                      <.active_session_card session={session} />
                    <% {:job, job} -> %>
                      <.active_job_card job={job} />
                  <% end %>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Panel 2: Recent Activity --%>
        <div class="bg-base-200 rounded-box p-4 h-full flex flex-col">
          <div class="flex items-center justify-between mb-4">
            <h3 class="font-semibold flex items-center gap-2">
              <.icon name="hero-clock" class="w-5 h-5 text-primary" /> Recent Activity
            </h3>
            <%= if @recent_activity != [] do %>
              <button
                class="btn btn-xs btn-ghost text-error"
                phx-click="clear_recent_activity"
                data-confirm="Clear all recent activity?"
                title="Clear all"
              >
                <.icon name="hero-trash" class="w-3 h-3" />
              </button>
            <% end %>
          </div>

          <%= if @recent_activity == [] do %>
            <div class="flex-1 flex flex-col items-center justify-center p-8 text-base-content/50">
              <.icon name="hero-clock" class="w-12 h-12 mb-2 opacity-20" />
              <span class="text-sm">No recent activity</span>
            </div>
          <% else %>
            <div class="overflow-y-auto max-h-[500px] pr-1 -mr-1">
              <div class="space-y-0 divide-y divide-base-300 bg-base-100 rounded-box border border-base-300">
                <%= for item <- @recent_activity do %>
                  <%= if item.type == :transcode_job do %>
                    <.recent_job_card job={item.data} />
                  <% else %>
                    <.recent_watch_card progress={item.data} />
                  <% end %>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Activity Sub-Components
  # ============================================================================

  attr :session, :map, required: true

  defp active_session_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-3 flex-row items-center gap-3">
        <div class="avatar placeholder">
          <div class="bg-neutral text-neutral-content rounded-full w-10">
            <span class="text-sm uppercase">
              {String.slice(user_label(@session.user), 0, 2)}
            </span>
          </div>
        </div>
        <div class="flex-1 min-w-0">
          <div class="font-medium text-sm truncate" title={@session.media_title}>
            {@session.media_title}
          </div>
          <div class="text-xs opacity-60 truncate">
            {@session.episode_info || "Movie"}
          </div>
        </div>
        <span class={[
          "badge badge-xs badge-outline",
          if(@session.mode == :transcode, do: "badge-warning", else: "badge-success")
        ]}>
          {if @session.mode == :transcode, do: "Transcode", else: "Direct"}
        </span>
      </div>
    </div>
    """
  end

  attr :job, :map, required: true

  defp active_job_card(assigns) do
    assigns = assign(assigns, :title, transcode_job_title(assigns.job))

    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-3">
        <div class="flex justify-between items-start gap-2 mb-2">
          <div class="min-w-0 flex-1">
            <div class="font-medium text-sm truncate" title={@title}>{@title}</div>
            <%= if @job.user_id && @job.user do %>
              <div class="text-xs opacity-60 flex items-center gap-1">
                <.icon name="hero-user" class="w-3 h-3" />
                {user_label(@job.user)}
              </div>
            <% end %>
          </div>
          <div class="flex items-center gap-1">
            <%= cond do %>
              <% @job.type == "direct" -> %>
                <span class="badge badge-xs badge-success" title="Direct Play">Direct</span>
              <% @job.type == "stream" -> %>
                <span class="badge badge-xs badge-info" title="Streaming">Stream</span>
              <% true -> %>
                <span class="badge badge-xs badge-ghost" title="Download">DL</span>
            <% end %>
            <span
              class={[
                "badge badge-xs",
                case @job.status do
                  "playing" -> "badge-success"
                  "transcoding" -> "badge-primary"
                  _ -> "badge-ghost"
                end
              ]}
              title={@job.error}
            >
              {@job.status}
            </span>
            <button
              class="btn btn-ghost btn-xs btn-square text-error -mr-1"
              phx-click="delete_transcode_job"
              phx-value-id={@job.id}
              data-confirm={if @job.type in ["stream", "direct"], do: "Stop this session?", else: nil}
            >
              <.icon name="hero-x-mark" class="w-3 h-3" />
            </button>
          </div>
        </div>

        <%= if @job.status != "playing" do %>
          <progress
            class="progress progress-primary w-full h-1"
            value={@job.progress * 100}
            max="100"
          ></progress>
        <% end %>

        <div class="flex justify-between text-xs mt-2 opacity-60 font-mono">
          <div class="flex gap-2">
            <span>{@job.resolution}</span>
            <%= if @job.file_size do %>
              <span>• {format_size(@job.file_size)}</span>
            <% end %>
          </div>
          <%= if @job.started_at do %>
            <span title={Calendar.strftime(@job.started_at, "%Y-%m-%d %H:%M:%S")}>
              {relative_time(@job.started_at)}
            </span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :job, :map, required: true

  defp recent_job_card(assigns) do
    assigns = assign(assigns, :title, transcode_job_title(assigns.job))

    ~H"""
    <div class="p-3 flex items-center gap-3 hover:bg-base-200/50 transition-colors">
      <div class={[
        "flex-shrink-0 w-6 h-6 flex items-center justify-center rounded-full",
        if(@job.status == "ready", do: "text-success", else: "text-error")
      ]}>
        <.icon
          name={if @job.status == "ready", do: "hero-check-circle", else: "hero-x-circle"}
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

  defp recent_watch_card(assigns) do
    poster_path =
      if assigns.progress.media_item && assigns.progress.media_item.metadata,
        do: assigns.progress.media_item.metadata.poster_path

    title =
      cond do
        assigns.progress.episode && assigns.progress.media_item ->
          ep = assigns.progress.episode
          "#{assigns.progress.media_item.title} - S#{ep.season_number}E#{ep.episode_number}"

        assigns.progress.media_item ->
          assigns.progress.media_item.title

        true ->
          "Unknown Media"
      end

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

  # ============================================================================
  # Helper Functions
  # ============================================================================

  # Users created through OIDC have no username (see `Mydia.Accounts.User.role_changeset/2`),
  # so fall back to the email before giving up entirely.
  defp user_label(nil), do: "Unknown"
  defp user_label(%{username: username}) when is_binary(username) and username != "", do: username
  defp user_label(%{email: email}) when is_binary(email) and email != "", do: email
  defp user_label(_), do: "Unknown"

  # Helper for image URLs
  defp build_image_url(nil), do: nil
  defp build_image_url(path) when is_binary(path), do: ImageUrl.image_url(path, "w92")
  defp build_image_url(_), do: nil

  # Helper for file size formatting
  defp format_size(nil), do: "-"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_size(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"

  defp format_size(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 1)} GB"

  # Helper for relative time formatting
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

  defp health_badge(:healthy), do: "badge-success"
  defp health_badge(:unhealthy), do: "badge-error"
  defp health_badge(:unknown), do: "badge-warning"
  defp health_badge(_), do: "badge-ghost"
end
