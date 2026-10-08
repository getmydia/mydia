defmodule MydiaWeb.AdminDownloadClientsLive.CategoryRoutingComponents do
  @moduledoc false
  use MydiaWeb, :html

  attr :content_types, :list, required: true
  attr :categories_value, :map, required: true
  attr :legacy_category, :string, required: true
  attr :has_legacy_only?, :boolean, required: true

  def categories_section(assigns) do
    ~H"""
    <div class="space-y-3" id="download-client-categories">
      <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
        <.icon name="hero-tag" class="w-4 h-4" />
        <span>Categories</span>
      </div>

      <%= if @has_legacy_only? do %>
        <div class="alert alert-warning text-sm py-2">
          <.icon name="hero-information-circle" class="w-4 h-4" />
          <span>
            This client uses the legacy single category
            <code class="font-mono">{@legacy_category}</code>
            for all content types. Saving will migrate it to per-content-type categories below.
          </span>
        </div>
      <% end %>

      <p class="text-xs text-base-content/50">
        Optional. Routes downloads to the right client-side category by content type.
      </p>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
        <%= for {key, label} <- @content_types do %>
          <.input
            name={"download_client_config[categories][#{key}]"}
            id={"download-client-categories-#{key}"}
            type="text"
            label={label}
            placeholder="mydia"
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
        <span>External torrents</span>
      </div>

      <p class="text-xs text-base-content/50">
        What Mydia does with torrents already in this client that it did not add.
        Anything Mydia does not adopt stays visible under Downloads, External,
        where you can match it by hand.
      </p>

      <.input
        field={@download_client_form[:external_torrents]}
        id="download-client-external-torrents"
        type="select"
        label="Mode"
        options={@external_torrent_modes}
      />

      <ul class="text-xs text-base-content/50 space-y-1 list-disc list-inside">
        <li>
          <span class="font-medium">Automatic</span>
          uses your category when you have one set, and adopts any library match
          otherwise.
        </li>
        <li>
          <span class="font-medium">Adopt any match</span>
          imports every torrent here that matches something in your library.
        </li>
        <%= if @category_capable_type? do %>
          <li>
            <span class="font-medium">Only my category</span>
            imports only torrents tagged with this client's configured category.
          </li>
        <% end %>
        <li>
          <span class="font-medium">Ignore</span>
          never imports from this client. Use this for a client you manage yourself.
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
        <span>Advanced: Priority profile</span>
        <span class="text-xs text-base-content/50">
          (overrides the per-tier value sent to the client)
        </span>
      </summary>
      <div class="collapse-content space-y-3">
        <p class="text-xs text-base-content/50">
          Map each abstract priority tier to the value this client understands.
          Leave blank to use the adapter's built-in default (shown as placeholder).
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
