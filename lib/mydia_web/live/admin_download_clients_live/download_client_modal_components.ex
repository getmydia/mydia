defmodule MydiaWeb.AdminDownloadClientsLive.DownloadClientModalComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Downloads.StallDetector
  alias Mydia.Settings

  alias MydiaWeb.AdminDownloadClientsLive.CategoryRoutingComponents
  alias MydiaWeb.AdminDownloadClientsLive.ConnectionFieldsComponents
  alias MydiaWeb.AdminDownloadClientsLive.SeedboxComponents

  # Client types that surface category configuration in the admin form.
  # Blackhole uses filesystem paths and debrid uses a hosted service, so
  # neither has a per-content-type category taxonomy.
  @category_aware_types ~w(qbittorrent transmission rtorrent sabnzbd nzbget)

  # Client types that surface the 5-tier priority profile UI. Same set as
  # `@category_aware_types` minus blackhole — every adapter that maps the
  # abstract priority to a native value is listed here.
  @priority_profile_types ~w(qbittorrent transmission rtorrent sabnzbd nzbget)

  # Client types that can point at a remote host reachable over SFTP, so they
  # surface the remote seedbox (pull-over-SFTP) section. Blackhole and debrid
  # don't run on a remote host in this sense, and sabnzbd/nzbget (Usenet) have
  # no seedbox concept.
  @remote_fetch_types ~w(qbittorrent transmission rqbit rtorrent)

  # Client types the untracked scan actually visits. Usenet, debrid, and
  # blackhole clients have no concept of a foreign torrent sitting in them, so
  # the External torrents control is meaningless for them. Mirrors
  # `@torrent_client_types` in `Mydia.Downloads.ExternalTorrents`.
  @external_torrent_types ~w(qbittorrent transmission rqbit)

  # `category_only` is omitted for a client that cannot report a category back
  # (rqbit), rather than offered and left to adopt nothing in silence. The
  # changeset rejects that combination too, in both config layers.
  @external_torrent_modes [
    {"Automatic (recommended)", "auto"},
    {"Adopt any match", "adopt"},
    {"Only my category", "category_only"},
    {"Ignore", "ignore"}
  ]

  # Placeholder hints shown in the per-tier priority profile inputs. Each
  # adapter has its own native priority value domain; the placeholder mirrors
  # the hardcoded default mapping so users see what value they'd get if they
  # left the override blank.
  @priority_profile_placeholders %{
    "sabnzbd" => %{
      "verylow" => "-100",
      "low" => "-1",
      "normal" => "0",
      "high" => "1",
      "veryhigh" => "2"
    },
    "nzbget" => %{
      "verylow" => "-100",
      "low" => "-50",
      "normal" => "0",
      "high" => "50",
      "veryhigh" => "100"
    },
    "qbittorrent" => %{
      "verylow" => "(unset)",
      "low" => "(unset)",
      "normal" => "(unset)",
      "high" => "(unset)",
      "veryhigh" => "(unset)"
    },
    "transmission" => %{
      "verylow" => "-1",
      "low" => "-1",
      "normal" => "0",
      "high" => "1",
      "veryhigh" => "1"
    },
    "rtorrent" => %{
      "verylow" => "0",
      "low" => "1",
      "normal" => "2",
      "high" => "3",
      "veryhigh" => "3"
    }
  }

  @priority_tiers [
    {"verylow", "Very Low"},
    {"low", "Low"},
    {"normal", "Normal"},
    {"high", "High"},
    {"veryhigh", "Very High"}
  ]

  @content_types [
    {"movie", "Movies"},
    {"tv", "TV Shows"},
    {"music", "Music"}
  ]

  @doc """
  Renders the Download Client modal.
  """
  attr :download_client_form, :any, required: true
  attr :download_client_mode, :atom, required: true
  attr :testing_download_client_connection, :boolean, default: false
  attr :editing_download_client, :any, default: nil

  def download_client_modal(assigns) do
    # Get the currently selected type to conditionally show fields. The
    # `nil`/`""` clauses match before the catch-all `is_atom` branch
    # because `is_atom(nil)` would otherwise stringify to `"nil"` for a
    # fresh changeset — defaulting to qBittorrent yields a more useful
    # empty form.
    selected_type =
      case Phoenix.HTML.Form.input_value(assigns.download_client_form, :type) do
        nil -> "qbittorrent"
        "" -> "qbittorrent"
        type when is_binary(type) -> type
        type when is_atom(type) -> Atom.to_string(type)
        _ -> "qbittorrent"
      end

    form = assigns.download_client_form

    # Derive the current per-content-type categories map for prefilling
    # inputs. Falls back to the legacy single `:category` value for all
    # three slots when the new map is empty — this surfaces existing
    # behaviour without forcing the user to re-enter on first edit.
    categories_value =
      case Phoenix.HTML.Form.input_value(form, :categories) do
        map when is_map(map) and map_size(map) > 0 -> map
        _ -> %{}
      end

    legacy_category =
      case Phoenix.HTML.Form.input_value(form, :category) do
        value when is_binary(value) -> value
        _ -> ""
      end

    has_legacy_only? = map_size(categories_value) == 0 and legacy_category != ""

    priority_profile_value =
      case Phoenix.HTML.Form.input_value(form, :priority_profile) do
        map when is_map(map) -> map
        _ -> %{}
      end

    show_categories? = selected_type in @category_aware_types
    show_priority_profile? = selected_type in @priority_profile_types
    show_remote_fetch? = selected_type in @remote_fetch_types
    show_external_torrents? = selected_type in @external_torrent_types

    # rqbit reports neither categories nor labels, so scoping to a category can
    # never match there. Drop the option rather than let it look available.
    external_torrent_modes =
      if category_capable_type?(selected_type) do
        @external_torrent_modes
      else
        Enum.reject(@external_torrent_modes, fn {_label, value} -> value == "category_only" end)
      end

    priority_placeholders = Map.get(@priority_profile_placeholders, selected_type, %{})

    assigns =
      assigns
      |> assign(:selected_type, selected_type)
      |> assign(:categories_value, categories_value)
      |> assign(:legacy_category, legacy_category)
      |> assign(:has_legacy_only?, has_legacy_only?)
      |> assign(:priority_profile_value, priority_profile_value)
      |> assign(:show_categories?, show_categories?)
      |> assign(:show_priority_profile?, show_priority_profile?)
      |> assign(:show_remote_fetch?, show_remote_fetch?)
      |> assign(:show_external_torrents?, show_external_torrents?)
      |> assign(:external_torrent_modes, external_torrent_modes)
      |> assign(:category_capable_type?, category_capable_type?(selected_type))
      |> assign(:priority_placeholders, priority_placeholders)
      |> assign(:priority_tiers, @priority_tiers)
      |> assign(:content_types, @content_types)

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <.form
          for={@download_client_form}
          id="download-client-form"
          phx-change="validate_download_client"
          phx-submit="save_download_client"
        >
          <%!-- Header --%>
          <div class="flex items-center justify-between mb-5">
            <div class="flex items-center gap-3">
              <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
                <.icon
                  name={
                    if(@download_client_mode == :new,
                      do: "hero-plus-circle",
                      else: "hero-pencil-square"
                    )
                  }
                  class="w-5 h-5 text-primary"
                />
              </div>
              <div>
                <h3 class="font-bold text-lg">
                  {if @download_client_mode == :new,
                    do: "Add Download Client",
                    else: "Edit Download Client"}
                </h3>
                <p class="text-sm text-base-content/60">
                  {if @download_client_mode == :new,
                    do: "Configure a new download client",
                    else: "Update client settings"}
                </p>
              </div>
            </div>
            <label class="label cursor-pointer gap-2">
              <span class="label-text text-sm">Enabled</span>
              <input type="hidden" name={@download_client_form[:enabled].name} value="false" />
              <input
                type="checkbox"
                name={@download_client_form[:enabled].name}
                value="true"
                checked={
                  Phoenix.HTML.Form.normalize_value("checkbox", @download_client_form[:enabled].value)
                }
                class="toggle toggle-success toggle-sm"
              />
            </label>
          </div>
          <div class="space-y-5">
            <%!-- Basic Settings Row --%>
            <div class="grid grid-cols-6 gap-3">
              <div class="col-span-6 md:col-span-3">
                <.input field={@download_client_form[:name]} type="text" label="Name" required />
              </div>
              <div class="col-span-4 md:col-span-2">
                <.input
                  field={@download_client_form[:type]}
                  type="select"
                  label="Type"
                  options={[
                    {"qBittorrent", "qbittorrent"},
                    {"Transmission", "transmission"},
                    {"rqbit", "rqbit"},
                    {"rTorrent", "rtorrent"},
                    {"Blackhole", "blackhole"},
                    {"SABnzbd", "sabnzbd"},
                    {"NZBGet", "nzbget"},
                    {"Debrid", "debrid"}
                  ]}
                  required
                />
              </div>
              <div class="col-span-2 md:col-span-1">
                <.input field={@download_client_form[:priority]} type="number" label="Priority" />
              </div>
            </div>

            <div class="divider my-1"></div>

            <%= cond do %>
              <% @selected_type == "debrid" -> %>
                <ConnectionFieldsComponents.debrid_fields download_client_form={@download_client_form} />
              <% @selected_type == "blackhole" -> %>
                <ConnectionFieldsComponents.blackhole_fields download_client_form={
                  @download_client_form
                } />
              <% true -> %>
                <ConnectionFieldsComponents.network_fields download_client_form={
                  @download_client_form
                } />
            <% end %>

            <%!-- Per-content-type categories. Hidden for blackhole and debrid clients. --%>
            <%= if @show_categories? do %>
              <CategoryRoutingComponents.categories_section
                content_types={@content_types}
                categories_value={@categories_value}
                legacy_category={@legacy_category}
                has_legacy_only?={@has_legacy_only?}
              />
            <% end %>

            <%!-- What to do with torrents this client already holds that Mydia
                 did not add. See Mydia.Downloads.ExternalPolicy and #531. --%>
            <%= if @show_external_torrents? do %>
              <CategoryRoutingComponents.external_torrents_section
                download_client_form={@download_client_form}
                external_torrent_modes={@external_torrent_modes}
                category_capable_type?={@category_capable_type?}
              />
            <% end %>

            <%!-- Stalled timeout. Visible for every client type. The entered
                 value is only the FIRST threshold; the give-up deadline is
                 derived from it and was previously invisible everywhere. --%>
            <div class="space-y-2">
              <.input
                field={@download_client_form[:incomplete_grace_minutes]}
                id="download-client-grace-minutes"
                type="number"
                label="Stalled timeout (minutes)"
                placeholder="60"
                min="1"
              />
              <% grace = grace_minutes_value(@download_client_form[:incomplete_grace_minutes].value) %>
              <% escalation = StallDetector.escalation_minutes(grace) %>
              <p class="text-xs text-base-content/50">
                Flagged as stalled after {format_duration(grace * 60)} without progress.
                If it still hasn't moved {format_duration(escalation * 60)} later
                ({format_duration((grace + escalation) * 60)} total), Mydia removes it
                and searches for a different release.
              </p>
            </div>

            <%!-- Priority profile (collapsed advanced section). --%>
            <%= if @show_priority_profile? do %>
              <CategoryRoutingComponents.priority_profile_section
                priority_tiers={@priority_tiers}
                priority_placeholders={@priority_placeholders}
                priority_profile_value={@priority_profile_value}
              />
            <% end %>

            <%!-- Remote seedbox (SFTP pull). Visible only for network torrent-client
                 types that can point at a remote host. --%>
            <%= if @show_remote_fetch? do %>
              <SeedboxComponents.remote_fetch_section download_client_form={@download_client_form} />
            <% end %>

            <div class="divider my-1"></div>

            <%!-- Options Section --%>
            <div class="space-y-3">
              <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
                <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
                <span>Options</span>
              </div>

              <div class="flex items-center justify-between bg-base-200 rounded-lg px-4 py-3">
                <div class="flex items-center gap-3">
                  <.icon name="hero-trash" class="w-4 h-4 text-base-content/60" />
                  <div>
                    <span class="text-sm font-medium">Remove After Import</span>
                    <p class="text-xs text-base-content/50">
                      Remove downloads from the client after importing. Torrent clients
                      that support seeding wait until the torrent is stopped or paused
                      (seed ratio/time), then remove. Usenet and similar clients remove
                      immediately.
                    </p>
                  </div>
                </div>
                <input
                  type="hidden"
                  name={@download_client_form[:remove_completed].name}
                  value="false"
                />
                <input
                  type="checkbox"
                  name={@download_client_form[:remove_completed].name}
                  value="true"
                  checked={
                    Phoenix.HTML.Form.normalize_value(
                      "checkbox",
                      @download_client_form[:remove_completed].value
                    )
                  }
                  class="toggle toggle-primary toggle-sm"
                />
              </div>
            </div>
          </div>

          <%!-- Modal Actions --%>
          <div class="modal-action mt-6 pt-4 border-t border-base-300">
            <button type="button" class="btn btn-ghost" phx-click="close_download_client_modal">
              Cancel
            </button>
            <button
              type="button"
              class="btn btn-outline btn-secondary gap-2"
              phx-click="test_download_client_connection"
              disabled={@testing_download_client_connection}
            >
              <%= if @testing_download_client_connection do %>
                <span class="loading loading-spinner loading-sm"></span> Testing...
              <% else %>
                <.icon name="hero-signal" class="w-4 h-4" /> Test Connection
              <% end %>
            </button>
            <button type="submit" class="btn btn-primary gap-2">
              <.icon name="hero-check" class="w-4 h-4" />
              {if @download_client_mode == :new, do: "Add Client", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_download_client_modal"></div>
    </div>
    """
  end

  # Compares as strings rather than round-tripping through
  # String.to_existing_atom/1: the form's type is a string, and there is no
  # reason to convert just to compare. Sourced from the schema so the UI and
  # the two changeset validations cannot disagree about which clients qualify.
  defp category_capable_type?(type) when is_binary(type) do
    type in Enum.map(Settings.DownloadClientConfig.category_capable_types(), &Atom.to_string/1)
  end

  # The form value arrives as a string while the operator types, as an integer
  # from a loaded config, and as nil for a fresh form. Anything unusable falls
  # back to the schema default so the help text never renders a broken number.
  defp grace_minutes_value(value) do
    case value do
      n when is_integer(n) and n > 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 -> n
          _ -> Settings.default_grace_minutes()
        end

      _ ->
        Settings.default_grace_minutes()
    end
  end
end
