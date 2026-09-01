defmodule MydiaWeb.SectionLive.New do
  @moduledoc """
  Preset picker for adding a sidebar section.

  This is a route rather than a modal in the layout because the layout is a
  function component and cannot handle events.
  """
  use MydiaWeb, :live_view

  alias Mydia.Collections
  alias Mydia.Collections.SectionPresets

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Add a section")
     |> assign(:presets, SectionPresets.all())}
  end

  @impl true
  def handle_event("create", %{"preset" => key}, socket) do
    user = socket.assigns.current_user

    with %{} = preset <- SectionPresets.get(key),
         {:ok, collection} <- find_or_create(user, preset) do
      {:noreply, push_navigate(socket, to: ~p"/sections/#{collection.id}")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "That section type is not available.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create that section.")}
    end
  end

  # A user who clicks the same preset twice should land on the section they
  # already have rather than growing a duplicate sidebar entry.
  defp find_or_create(user, preset) do
    case Enum.find(Collections.list_pinned_sections(user), &(&1.name == preset.name)) do
      nil -> create(user, preset)
      existing -> {:ok, existing}
    end
  end

  defp create(user, preset) do
    with {:ok, collection} <-
           Collections.create_collection(user, %{
             name: preset.name,
             type: "smart",
             visibility: "private",
             smart_rules: Jason.encode!(preset.rules)
           }) do
      Collections.pin_section(user, collection,
        sidebar_icon: preset.icon,
        exclusive: preset.exclusive
      )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {assigns}>
      <div class="max-w-2xl mx-auto py-8">
        <h1 class="text-2xl font-bold mb-2">Add a section</h1>
        <p class="text-base-content/70 mb-6">
          A section is a saved filter pinned to your sidebar. It is yours alone;
          nobody else's sidebar changes.
        </p>

        <ul class="space-y-3">
          <li :for={preset <- @presets}>
            <button
              id={"preset-#{preset.key}"}
              phx-click="create"
              phx-value-preset={preset.key}
              class="card bg-base-200 hover:bg-base-300 transition-colors w-full text-left"
            >
              <div class="card-body flex-row items-center gap-4 py-4">
                <.icon name={preset.icon} class="w-8 h-8 text-primary shrink-0" />
                <div>
                  <div class="font-semibold">{preset.name}</div>
                  <div class="text-sm text-base-content/70">{preset.description}</div>
                </div>
              </div>
            </button>
          </li>
          <li>
            <.link
              id="preset-custom"
              navigate={~p"/collections"}
              class="card bg-base-200 hover:bg-base-300 transition-colors w-full"
            >
              <div class="card-body flex-row items-center gap-4 py-4">
                <.icon name="hero-squares-2x2" class="w-8 h-8 text-primary shrink-0" />
                <div>
                  <div class="font-semibold">Custom</div>
                  <div class="text-sm text-base-content/70">
                    Build a smart collection with your own rules, then pin it.
                  </div>
                </div>
              </div>
            </.link>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
