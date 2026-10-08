defmodule MydiaWeb.AdminQualityProfilesLive.ProfileFormTabs do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  Renders the Basic Info tab content for the Quality Profile modal.
  """
  attr :form, :any, required: true

  def quality_profile_basic_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- System Profile Indicator --%>
      <%= if Ecto.Changeset.get_field(@form.source, :is_system, false) do %>
        <div class="alert alert-warning">
          <.icon name="hero-lock-closed" class="w-5 h-5" />
          <div>
            <div class="font-semibold">System Profile</div>
            <div class="text-sm">
              This is a built-in system profile. Some fields may be restricted.
            </div>
          </div>
        </div>
      <% end %>

      <.input field={@form[:name]} type="text" label="Name" required />

      <.input
        field={@form[:description]}
        type="textarea"
        label="Description"
        rows="3"
      />

      <.input
        field={@form[:upgrades_allowed]}
        type="checkbox"
        label="Allow automatic quality upgrades"
      />

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.input
          field={@form[:upgrade_until_score]}
          type="number"
          id="quality-profile-upgrade-score"
          label="Upgrade cutoff score"
          min="0"
          max="100"
          hint="Files scoring below this are eligible for an automatic upgrade. Setting it near 100 means almost nothing is ever good enough, so the sweep will keep searching indefinitely."
        />

        <.input
          field={@form[:min_upgrade_margin]}
          type="number"
          id="quality-profile-upgrade-margin"
          label="Minimum upgrade margin"
          min="0"
          max="100"
          hint="How much higher a candidate release's score must be than the current file's before it counts as a real upgrade. Keeps a sweep from swapping files for a negligible gain."
        />
      </div>

      <.input
        field={@form[:grab_delay_hours]}
        type="number"
        id="quality-profile-grab-delay"
        label="Wait before grabbing (hours)"
        min="0"
        max="168"
        hint="Hold automatic grabs until the first acceptable release is this old, so better releases have time to appear. A release that already meets the upgrade cutoff is grabbed right away. Searches you start yourself never wait. 0 grabs immediately."
      />
    </div>
    """
  end

  @doc """
  Renders the Exclude tab: release types this profile will never grab.

  The hidden input before the checkbox group matters. Browsers omit unchecked
  checkboxes entirely, so without it, clearing every box would submit no key at
  all, `cast` would see no change, and the previous list would silently persist
  with no way for the operator to turn the exclusion off.
  """
  attr :form, :any, required: true

  def quality_profile_exclude_tab(assigns) do
    assigns = assign(assigns, :cam_tier, Mydia.Quality.Sources.cam_tier())

    ~H"""
    <div class="space-y-4">
      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Never Grab These Release Types</span>
          <span class="label-text-alt text-xs">Dropped before ranking, even if nothing else is available</span>
        </label>

        <p class="text-sm opacity-70 mb-3">
          Camcorder and pre-release captures. When a film is still in cinemas these are
          often the only releases that exist, so without this list Mydia will download one
          rather than wait for a proper release.
        </p>

        <input
          type="hidden"
          name="quality_profile[quality_standards][excluded_sources][]"
          value=""
        />

        <div class="grid grid-cols-2 md:grid-cols-3 gap-2">
          <%= for source <- @cam_tier do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][excluded_sources][]"
                value={source}
                checked={
                  source in (get_in(
                               Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                               [:excluded_sources]
                             ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{source}</span>
            </label>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
