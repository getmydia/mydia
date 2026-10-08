defmodule MydiaWeb.AdminIndexersLive.LibraryConfigComponents do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  Renders the Library Indexer Config modal.

  Dynamically renders form fields based on the indexer's settings definition.
  """
  attr :configuring_library_indexer, :any, required: true
  attr :settings, :list, default: []
  attr :testing, :boolean, default: false
  attr :test_result, :map, default: nil

  def library_config_modal(assigns) do
    ~H"""
    <.admin_modal
      id="library-indexer-config-modal"
      icon="hero-cog-6-tooth"
      title={"Configure #{@configuring_library_indexer.name}"}
      subtitle={indexer_subtitle(@configuring_library_indexer)}
      on_close="close_library_config_modal"
    >
      <%!-- Info banner --%>
      <div class="alert mb-4">
        <.icon name="hero-information-circle" class="w-5 h-5 shrink-0" />
        <span class="text-sm">
          <%= if @configuring_library_indexer.type == "private" do %>
            This indexer requires authentication to search and download torrents.
          <% else %>
            Configure optional settings for this indexer.
          <% end %>
        </span>
      </div>

      <form id="library-indexer-config-form" phx-submit="save_library_indexer_config">
        <%!-- Settings Card --%>
        <div class="bg-base-200 rounded-box p-3">
          <div class="space-y-4">
            <%= if @settings == [] do %>
              <%!-- Fallback: Generic username/password form --%>
              <div class="form-control">
                <label class="label">
                  <span class="label-text font-medium">Username</span>
                </label>
                <input
                  type="text"
                  name="config[username]"
                  value={get_in(@configuring_library_indexer.config || %{}, ["username"])}
                  class="input input-bordered w-full"
                  placeholder="Enter your username"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text font-medium">Password</span>
                </label>
                <input
                  type="password"
                  name="config[password]"
                  value={get_in(@configuring_library_indexer.config || %{}, ["password"])}
                  class="input input-bordered w-full"
                  placeholder="Enter your password"
                />
              </div>
            <% else %>
              <%!-- Dynamic fields from indexer definition --%>
              <%= for setting <- @settings do %>
                <.library_config_field
                  setting={setting}
                  config={@configuring_library_indexer.config || %{}}
                />
              <% end %>
            <% end %>
          </div>
        </div>

        <%!-- Test Result --%>
        <%= if @test_result do %>
          <div class={[
            "alert mt-4",
            if(@test_result.success, do: "alert-success", else: "alert-error")
          ]}>
            <.icon
              name={if @test_result.success, do: "hero-check-circle", else: "hero-x-circle"}
              class="w-5 h-5 shrink-0"
            />
            <div>
              <div class="font-medium">{@test_result.message}</div>
              <%= if @test_result.response_time_ms do %>
                <div class="text-sm opacity-80">
                  Response time: {@test_result.response_time_ms}ms
                </div>
              <% end %>
              <%= if @test_result.error do %>
                <div class="text-sm opacity-80">{@test_result.error}</div>
              <% end %>
            </div>
          </div>
        <% end %>

        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_library_config_modal">
            Cancel
          </button>
          <button
            type="submit"
            name="action"
            value="test"
            class="btn btn-outline btn-secondary"
            disabled={@testing}
          >
            <%= if @testing do %>
              <span class="loading loading-spinner loading-sm"></span> Testing...
            <% else %>
              <.icon name="hero-signal" class="w-4 h-4" /> Test Connection
            <% end %>
          </button>
          <button type="submit" name="action" value="save" class="btn btn-primary">Save</button>
        </.admin_modal_actions>
      </form>
    </.admin_modal>
    """
  end

  defp indexer_subtitle(indexer) do
    [indexer.type, indexer.language]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  # Renders a single config field based on its type
  attr :setting, :map, required: true
  attr :config, :map, required: true

  defp library_config_field(assigns) do
    assigns =
      assigns
      |> assign(:field_name, assigns.setting.name)
      |> assign(
        :field_label,
        assigns.setting[:label] || humanize_field_name(assigns.setting.name)
      )
      |> assign(:field_type, assigns.setting.type)
      |> assign(:field_default, assigns.setting[:default])
      |> assign(:field_options, assigns.setting[:options])
      |> assign(
        :current_value,
        get_in(assigns.config, [assigns.setting.name]) || assigns.setting[:default]
      )

    ~H"""
    <div class="form-control">
      <%= case @field_type do %>
        <% "text" -> %>
          <label class="label">
            <span class="label-text font-medium">{@field_label}</span>
          </label>
          <input
            type="text"
            name={"config[#{@field_name}]"}
            value={@current_value}
            class="input input-bordered w-full"
          />
        <% "password" -> %>
          <label class="label">
            <span class="label-text font-medium">{@field_label}</span>
          </label>
          <input
            type="password"
            name={"config[#{@field_name}]"}
            value={@current_value}
            class="input input-bordered w-full"
          />
        <% "checkbox" -> %>
          <label class="label cursor-pointer justify-start gap-3">
            <input
              type="hidden"
              name={"config[#{@field_name}]"}
              value="false"
            />
            <input
              type="checkbox"
              name={"config[#{@field_name}]"}
              value="true"
              checked={@current_value == true or @current_value == "true"}
              class="checkbox checkbox-primary"
            />
            <span class="label-text font-medium">{@field_label}</span>
          </label>
        <% "select" -> %>
          <label class="label">
            <span class="label-text font-medium">{@field_label}</span>
          </label>
          <select name={"config[#{@field_name}]"} class="select select-bordered w-full">
            <%= if @field_options do %>
              <%= for {label, value} <- normalize_select_options(@field_options) do %>
                <option value={value} selected={to_string(@current_value) == to_string(value)}>
                  {label}
                </option>
              <% end %>
            <% end %>
          </select>
        <% "info" -> %>
          <label class="label">
            <span class="label-text font-medium">{@field_label}</span>
          </label>
          <div class="text-sm text-base-content/70 bg-base-300 p-3 rounded-lg">
            {@field_default || "No additional information"}
          </div>
        <% _ -> %>
          <%!-- Default to text input for unknown types --%>
          <label class="label">
            <span class="label-text font-medium">{@field_label}</span>
          </label>
          <input
            type="text"
            name={"config[#{@field_name}]"}
            value={@current_value}
            class="input input-bordered w-full"
          />
      <% end %>
    </div>
    """
  end

  defp humanize_field_name(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_field_name(name) when is_atom(name), do: humanize_field_name(Atom.to_string(name))

  defp normalize_select_options(options) when is_map(options) do
    Enum.map(options, fn {k, v} -> {v, k} end)
  end

  defp normalize_select_options(options) when is_list(options) do
    Enum.map(options, fn
      %{"name" => name, "value" => value} -> {name, value}
      %{name: name, value: value} -> {name, value}
      value when is_binary(value) -> {value, value}
      value -> {to_string(value), value}
    end)
  end

  defp normalize_select_options(_), do: []
end
