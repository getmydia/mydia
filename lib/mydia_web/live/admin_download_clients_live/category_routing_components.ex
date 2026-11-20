defmodule MydiaWeb.AdminDownloadClientsLive.CategoryRoutingComponents do
  @moduledoc false
  use MydiaWeb, :html

  # Client types that take per-content-type categories. Blackhole uses
  # filesystem paths and debrid uses a hosted service, so neither has one.
  @category_aware_types ~w(qbittorrent transmission rtorrent sabnzbd nzbget)

  @doc "Whether the admin UI offers categories for this client type."
  def category_aware_type?(type) when is_atom(type) and not is_nil(type),
    do: category_aware_type?(Atom.to_string(type))

  def category_aware_type?(type), do: type in @category_aware_types

  @doc "The content types a client can route to its own category, with labels."
  def content_types do
    [
      {"movie", gettext("Movies")},
      {"tv", gettext("TV Shows")},
      {"music", gettext("Music")}
    ]
  end

  @doc """
  What a client row says about its categories: one value when every content
  type shares it, one entry per content type otherwise, and "No category" when
  torrents are added without one (#1442). Falls back to the legacy single
  `category` field the same way `Mydia.Downloads.Queue.resolve_category/3` does.
  """
  def category_summary(client) do
    categories = client.categories || %{}
    legacy = present(client.category)

    resolved =
      for {key, label} <- content_types(),
          value = present(Map.get(categories, key)) || legacy,
          do: {label, value}

    case resolved |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [] ->
        gettext("No category")

      [value] when length(resolved) == 3 ->
        gettext("Category: %{category}", category: value)

      _mixed ->
        Enum.map_join(resolved, ", ", fn {label, value} ->
          gettext("%{content_type}: %{category}", content_type: label, category: value)
        end)
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  attr :content_types, :list, required: true
  attr :categories_value, :map, required: true
  attr :legacy_category, :string, required: true
  attr :has_legacy_only?, :boolean, required: true

  def categories_section(assigns) do
    ~H"""
    <div class="space-y-3" id="download-client-categories">
      <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
        <.icon name="hero-tag" class="w-4 h-4" />
        <span>{gettext("Categories")}</span>
      </div>

      <%= if @has_legacy_only? do %>
        <div class="alert alert-warning text-sm py-2">
          <.icon name="hero-information-circle" class="w-4 h-4" />
          <span>
            {gettext(
              "This client uses the legacy single category %{category} for all content types. Saving will migrate it to per-content-type categories below.",
              category: @legacy_category
            )}
          </span>
        </div>
      <% end %>

      <p class="text-xs text-base-content/50">
        {gettext("Optional. Routes downloads to the right client-side category by content type.")}
      </p>
      <%!-- No placeholder on these inputs: a grey sample value made empty
            fields look saved (#1442). --%>
      <p id="download-client-categories-hint" class="text-xs text-base-content/50">
        {gettext("Leave blank to add torrents without a category.")}
      </p>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
        <%= for {key, label} <- @content_types do %>
          <.input
            name={"download_client_config[categories][#{key}]"}
            id={"download-client-categories-#{key}"}
            type="text"
            label={label}
            value={
              Map.get(@categories_value, key) || (@has_legacy_only? && @legacy_category) ||
                ""
            }
          />
        <% end %>
      </div>
    </div>
    """
  end

  attr :download_client_form, :any, required: true
  attr :external_torrent_modes, :list, required: true
  attr :category_capable_type?, :boolean, required: true

  def external_torrents_section(assigns) do
    ~H"""
    <div class="space-y-3" id="download-client-external-torrents-section">
      <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
        <.icon name="hero-inbox-stack" class="w-4 h-4" />
        <span>{gettext("External torrents")}</span>
      </div>

      <p class="text-xs text-base-content/50">
        {gettext(
          "What Mydia does with torrents already in this client that it did not add. Anything Mydia does not adopt stays visible under Downloads, External, where you can match it by hand."
        )}
      </p>

      <.input
        field={@download_client_form[:external_torrents]}
        id="download-client-external-torrents"
        type="select"
        label={gettext("Mode")}
        options={@external_torrent_modes}
      />

      <ul class="text-xs text-base-content/50 space-y-1 list-disc list-inside">
        <li>
          {gettext(
            "Automatic uses your category when you have one set, and adopts any library match otherwise."
          )}
        </li>
        <li>
          {gettext(
            "Adopt any match imports every torrent here that matches something in your library."
          )}
        </li>
        <%= if @category_capable_type? do %>
          <li>
            {gettext(
              "Only my category imports only torrents tagged with this client's configured category."
            )}
          </li>
        <% end %>
        <li>
          {gettext(
            "Ignore never imports from this client. Use this for a client you manage yourself."
          )}
        </li>
      </ul>
    </div>
    """
  end

  attr :priority_tiers, :list, required: true
  attr :priority_placeholders, :map, required: true
  attr :priority_profile_value, :map, required: true

  def priority_profile_section(assigns) do
    ~H"""
    <details
      class="collapse collapse-arrow bg-base-200"
      id="download-client-priority-profile"
    >
      <summary class="collapse-title text-sm font-medium flex items-center gap-2">
        <.icon name="hero-bolt" class="w-4 h-4 text-base-content/60" />
        <span>{gettext("Advanced: Priority profile")}</span>
        <span class="text-xs text-base-content/50">
          {gettext("(overrides the per-tier value sent to the client)")}
        </span>
      </summary>
      <div class="collapse-content space-y-3">
        <p class="text-xs text-base-content/50">
          {gettext(
            "Map each abstract priority tier to the value this client understands. Leave blank to use the adapter's built-in default (shown as placeholder)."
          )}
        </p>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3">
          <%= for {key, label} <- @priority_tiers do %>
            <.input
              name={"download_client_config[priority_profile][#{key}]"}
              id={"download-client-priority-#{key}"}
              type="text"
              label={label}
              placeholder={Map.get(@priority_placeholders, key) || ""}
              value={Map.get(@priority_profile_value, key) || ""}
            />
          <% end %>
        </div>
      </div>
    </details>
    """
  end
end
