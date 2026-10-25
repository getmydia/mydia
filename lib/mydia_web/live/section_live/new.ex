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
     |> assign(:page_title, gettext("Add a section"))
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
        {:noreply, put_flash(socket, :error, gettext("That section type is not available."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not create that section."))}
    end
  end

  # The preset catalog lives in `Mydia.Collections.SectionPresets` with English
  # text. The stored collection name stays English (it is matched against the
  # catalog), so only the picker's display text is translated here.
  defp preset_name(%{key: "anime"}), do: gettext("Anime")
  defp preset_name(%{key: "cartoons"}), do: gettext("Cartoons")
  defp preset_name(%{key: "documentaries"}), do: gettext("Documentaries")
  defp preset_name(preset), do: preset.name

  defp preset_description(%{key: "anime"}),
    do: gettext("Japanese animation, movies and series, out of Movies and TV.")

  defp preset_description(%{key: "cartoons"}),
    do: gettext("Western animation, movies and series, out of Movies and TV.")

  defp preset_description(%{key: "documentaries"}),
    do: gettext("Anything tagged with the Documentary genre. Stays in Movies and TV.")

  defp preset_description(preset), do: preset.description

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
        <h1 class="text-2xl font-bold mb-2">{gettext("Add a section")}</h1>
        <p class="text-base-content/70 mb-6">
          {gettext(
            "A section is a saved filter pinned to your sidebar. It is yours alone; nobody else's sidebar changes."
          )}
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
                  <div class="font-semibold">{preset_name(preset)}</div>
                  <div class="text-sm text-base-content/70">{preset_description(preset)}</div>
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
                  <div class="font-semibold">{gettext("Custom")}</div>
                  <div class="text-sm text-base-content/70">
                    {gettext(
                      "Build a smart collection with your own rules, then use \"Pin to sidebar\" on it to add it here."
                    )}
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
