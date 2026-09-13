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
end
