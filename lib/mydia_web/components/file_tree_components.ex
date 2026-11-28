defmodule MydiaWeb.FileTreeComponents do
  @moduledoc """
  A selectable folder tree for a torrent's files.

  Renders the tree `Mydia.Downloads.FileTree.build/2` makes from a flat file
  list and a selection. It holds no state: checkbox clicks are sent to `target`
  as `"toggle_files"` (with `folder` or `index`) and `"toggle_all_files"`, and
  the owner updates the selection with `Mydia.Downloads.FileTree`.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents, only: [icon: 1]
  import MydiaWeb.Formatters, only: [format_file_size: 1]

  alias Mydia.Downloads.FileTree
  alias Mydia.Downloads.FileTree.{Folder, Leaf}

  attr :id, :string, required: true
  attr :files, :list, required: true
  attr :selected, :any, required: true, doc: "a MapSet of selected file indexes"
  attr :disabled, :boolean, default: false
  attr :target, :any, default: nil
  attr :show_progress, :boolean, default: false

  def file_tree(assigns) do
    tree = FileTree.build(assigns.files, assigns.selected)

    assigns =
      assigns
      |> assign(:tree, tree)
      |> assign(:all_state, FileTree.state(assigns.files, assigns.selected))
      |> assign(:selected_size, FileTree.selected_size(assigns.files, assigns.selected))
      |> assign(:total_size, Enum.sum(Enum.map(assigns.files, & &1.size)))

    ~H"""
    <div id={@id} class="flex flex-col gap-1">
      <label class="flex items-center gap-3 text-sm cursor-pointer pb-1 border-b border-base-300">
        <input
          type="checkbox"
          id={"#{@id}-all"}
          class="checkbox checkbox-sm"
          phx-hook="IndeterminateCheckbox"
          data-state={@all_state}
          checked={@all_state == :all}
          disabled={@disabled}
          phx-click="toggle_all_files"
          phx-target={@target}
        />
        <span class="text-base-content/70">
          {gettext("%{selected} of %{total} selected",
            selected: format_file_size(@selected_size),
            total: format_file_size(@total_size)
          )}
        </span>
      </label>
      <%= if @tree.path == "" do %>
        <.tree_node
          :for={child <- @tree.children}
          node={child}
          tree_id={@id}
          root_path={@tree.path}
          disabled={@disabled}
          target={@target}
          show_progress={@show_progress}
        />
      <% else %>
        <.tree_node
          node={@tree}
          tree_id={@id}
          root_path={@tree.path}
          disabled={@disabled}
          target={@target}
          show_progress={@show_progress}
        />
      <% end %>
    </div>
    """
  end

  attr :node, :any, required: true
  attr :tree_id, :string, required: true
  attr :root_path, :string, required: true
  attr :disabled, :boolean, required: true
  attr :target, :any, required: true
  attr :show_progress, :boolean, required: true

  defp tree_node(%{node: %Folder{}} = assigns) do
    ~H"""
    <details open={@node.path == @root_path} class="group">
      <summary class="flex items-center gap-3 text-sm cursor-pointer list-none py-1">
        <.icon
          name="hero-chevron-right"
          class="size-4 text-base-content/50 transition-transform group-open:rotate-90"
        />
        <input
          type="checkbox"
          id={"#{@tree_id}-folder-#{:erlang.phash2(@node.path)}"}
          class="checkbox checkbox-sm"
          phx-hook="IndeterminateCheckbox"
          data-state={@node.state}
          checked={@node.state == :all}
          disabled={@disabled}
          phx-click="toggle_files"
          phx-value-folder={@node.path}
          phx-target={@target}
        />
        <span class="min-w-0 flex-1 break-all font-medium">{@node.name}</span>
        <span class="text-xs text-base-content/60">{format_file_size(@node.size)}</span>
      </summary>
      <div class="ml-6 flex flex-col gap-1">
        <.tree_node
          :for={child <- @node.children}
          node={child}
          tree_id={@tree_id}
          root_path={@root_path}
          disabled={@disabled}
          target={@target}
          show_progress={@show_progress}
        />
      </div>
    </details>
    """
  end

  defp tree_node(%{node: %Leaf{}} = assigns) do
    ~H"""
    <label class="flex items-start gap-3 text-sm cursor-pointer py-0.5">
      <input
        type="checkbox"
        class="checkbox checkbox-sm mt-0.5"
        id={"#{@tree_id}-file-#{@node.index}"}
        data-state={if @node.selected?, do: :all, else: :none}
        checked={@node.selected?}
        disabled={@disabled}
        phx-click="toggle_files"
        phx-value-index={@node.index}
        phx-target={@target}
      />
      <span class="min-w-0 flex-1">
        <span class="block break-all">{@node.name}</span>
        <span class="flex items-center gap-2 text-xs text-base-content/60">
          <span>{format_file_size(@node.size)}</span>
          <progress
            :if={@show_progress and @node.selected?}
            class="progress progress-primary w-24"
            value={progress(@node.file)}
            max="100"
          ></progress>
        </span>
      </span>
    </label>
    """
  end

  defp progress(%{size: size, downloaded: downloaded}) when size > 0,
    do: min(100, trunc(downloaded * 100 / size))

  defp progress(_file), do: 0
end
