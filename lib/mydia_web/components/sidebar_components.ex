defmodule MydiaWeb.SidebarComponents do
  @moduledoc """
  The sidebar's building blocks: a nav link (`nav_item/1`), a section heading
  (`nav_title/1`), the admin running-jobs card (`running_jobs/1`) and the footer
  account chip (`account_menu/1`). `MydiaWeb.Layouts.app/1` composes them and
  decides which sections each role sees.

  Badges mean "needs attention" and render only above zero. Library totals are
  plain muted numbers, not badges.
  """
  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: MydiaWeb.Endpoint,
    router: MydiaWeb.Router,
    statics: MydiaWeb.static_paths()

  @doc """
  Whether `path` is the current page. With `exact` only the path itself counts;
  otherwise any sub-path does too, so `/movies/42` highlights Movies.
  """
  @spec nav_active?(String.t() | nil, String.t(), boolean()) :: boolean()
  def nav_active?(nil, _path, _exact), do: false
  def nav_active?(current, path, true), do: current == path

  def nav_active?(current, path, false),
    do: current == path || String.starts_with?(current, path <> "/")

  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :current_path, :string, default: nil
  attr :exact, :boolean, default: false, doc: "highlight only on the path itself"
  attr :id, :string, default: nil
  attr :badge, :integer, default: nil, doc: "needs-attention count, rendered only above 0"
  attr :badge_id, :string, default: nil
  attr :count, :integer, default: nil, doc: "informational total, rendered muted"
  attr :count_id, :string, default: nil

  @doc "One sidebar link."
  def nav_item(assigns) do
    ~H"""
    <li>
      <.link
        id={@id}
        navigate={@path}
        class={[nav_active?(@current_path, @path, @exact) && "menu-active"]}
      >
        <.icon name={@icon} class="w-5 h-5" />
        <span>{@label}</span>
        <span :if={@badge && @badge > 0} id={@badge_id} class="badge badge-primary badge-sm">
          {@badge}
        </span>
        <span :if={@count} id={@count_id} class="text-xs tabular-nums text-base-content/50">
          {@count}
        </span>
      </.link>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :action, doc: "a small control on the right of the heading"

  @doc "A sidebar section heading."
  def nav_title(assigns) do
    ~H"""
    <li id={@id} class="menu-title mt-4 flex flex-row items-center justify-between">
      <span>{@label}</span>
      {render_slot(@action)}
    </li>
    """
  end

  attr :executing_jobs, :list, required: true, doc: "maps with a :worker_name"

  @doc "The admin card listing jobs executing right now, linked to Background Jobs."
  def running_jobs(assigns) do
    ~H"""
    <div :if={@executing_jobs != []} class="px-4 py-2 border-t border-base-content/10">
      <.link
        id="sidebar-running-jobs"
        navigate={~p"/admin/jobs"}
        class="block bg-base-200 rounded-lg p-2 hover:bg-base-100 transition-colors"
      >
        <div class="flex items-center gap-2 text-sm font-medium mb-1">
          <span class="loading loading-spinner loading-xs text-primary"></span>
          <span>Running Jobs</span>
          <span class="badge badge-primary badge-xs">{length(@executing_jobs)}</span>
        </div>
        <ul class="text-xs opacity-70 space-y-0.5 pl-5">
          <li :for={job <- Enum.take(@executing_jobs, 3)} class="truncate">{job.worker_name}</li>
          <li :if={length(@executing_jobs) > 3} class="text-primary">
            +{length(@executing_jobs) - 3} more...
          </li>
        </ul>
      </.link>
    </div>
    """
  end
end
