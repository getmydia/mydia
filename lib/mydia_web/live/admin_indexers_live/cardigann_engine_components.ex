defmodule MydiaWeb.AdminIndexersLive.CardigannEngineComponents do
  @moduledoc """
  The Cardigann engine picker inside Library Indexers and the per-tracker
  verification badge. Rendering only; `MydiaWeb.AdminIndexersLive.Index`
  handles the events.

  The copy is qualitative on purpose: measured figures change with every bench
  run and live in the docs.
  """
  use MydiaWeb, :html

  alias Mydia.Indexers.Cardigann.EngineSupport
  alias Mydia.Indexers.Cardigann.EngineSwitcher.{Status, Transition}
  # The card copy lives in the functions below, not in the attribute, because
  # attributes are evaluated at compile time, before any locale is set.
  @engines [:builtin, :prowlarr]

  @docs_url "https://docs.mydia.dev/latest/using/how-to/cardigann-indexers/#using-the-prowlarr-based-engine-experimental"

  attr :display, Mydia.TimeDisplay, required: true
  attr :status, Status, required: true
  attr :cache_bytes, :integer, required: true
  attr :expanded, :boolean, default: false

  attr :only_verified, :list,
    required: true,
    doc: "names of library trackers verified only on the inactive engine"

  def engine_section(assigns) do
    assigns =
      assign(assigns,
        engines: @engines,
        docs_url: @docs_url,
        open?: assigns.expanded or not is_nil(assigns.status.transition)
      )

    ~H"""
    <section id="cardigann-engine" class="rounded-box bg-base-200/50 p-3 space-y-3">
      <div class="flex flex-wrap items-center gap-2">
        <.icon name="hero-cpu-chip" class="w-4 h-4 opacity-70" />
        <h3 class="font-semibold text-sm">{gettext("How library indexers run")}</h3>
        <.env_lock_badge :if={@status.locked} tip={gettext("Set by CARDIGANN_ENGINE")} />
        <span class="text-sm opacity-70">
          {gettext("Engine:")}
          <span id="cardigann-engine-active" class="font-medium">{engine_name(@status.active)}</span>
        </span>
        <button
          :if={is_nil(@status.transition)}
          id="cardigann-engine-toggle"
          type="button"
          phx-click="toggle_cardigann_engine"
          class="btn btn-ghost btn-xs text-primary"
        >
          {if @open?, do: gettext("Done"), else: gettext("Change")}
        </button>
        <a
          href={@docs_url}
          target="_blank"
          class="link link-hover text-xs opacity-70 ml-auto max-sm:inline-flex max-sm:items-center max-sm:min-h-6"
        >
          {gettext("How they compare")}
        </a>
      </div>
      <p class="text-xs opacity-70">
        {gettext(
          "Runs the tracker definitions in this library inside Mydia. Separate from Prowlarr connections, and needs no Prowlarr install."
        )}
      </p>

      <div :if={@open?} id="cardigann-engine-cards" class="space-y-3">
        <.form for={%{}} id="cardigann-engine-form" phx-change="switch_cardigann_engine">
          <div class="grid gap-3 sm:grid-cols-2">
            <label
              :for={engine <- @engines}
              for={"cardigann-engine-#{engine}"}
              class={[
                "card card-border bg-base-100 cursor-pointer transition-colors hover:border-primary/60",
                engine == selected(@status) && "border-primary",
                @status.locked && "cursor-not-allowed opacity-70"
              ]}
            >
              <div class="card-body p-4 gap-2">
                <div class="flex flex-wrap items-center gap-2">
                  <input
                    type="radio"
                    name="engine"
                    id={"cardigann-engine-#{engine}"}
                    value={engine}
                    class="radio radio-primary radio-sm"
                    checked={engine == selected(@status)}
                    disabled={@status.locked}
                  />
                  <span class="font-medium whitespace-nowrap">{engine_name(engine)}</span>
                  <span :if={engine == @status.active} class="badge badge-success badge-sm">
                    {gettext("Active")}
                  </span>
                  <span
                    :if={@status.transition && engine == @status.transition.target}
                    class="badge badge-info badge-sm"
                  >
                    {gettext("Switching")}
                  </span>
                  <span
                    :if={engine_badge(engine)}
                    id={"cardigann-engine-#{engine}-badge"}
                    class="badge badge-primary badge-sm"
                  >
                    {engine_badge(engine)}
                  </span>
                </div>
                <p id={"cardigann-engine-#{engine}-subline"} class="text-xs opacity-70 grow-0">
                  {engine_subline(engine)}
                </p>
                <ul class="text-sm space-y-1">
                  <li :for={pro <- engine_pros(engine)} class="flex gap-2">
                    <.icon name="hero-plus-circle" class="w-4 h-4 text-success shrink-0" />{pro}
                  </li>
                  <li :for={con <- engine_cons(engine)} class="flex gap-2 opacity-80">
                    <.icon name="hero-minus-circle" class="w-4 h-4 text-warning shrink-0" />{con}
                  </li>
                </ul>
              </div>
            </label>
          </div>
        </.form>

        <button
          :if={@status.active == :builtin and is_nil(@status.transition) and @cache_bytes > 0}
          id="cardigann-engine-remove-cache"
          type="button"
          phx-click="remove_cardigann_engine_cache"
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-trash" class="w-3 h-3" />
          {gettext("Remove cached Prowlarr-based engine (%{size})", size: format_mb(@cache_bytes))}
        </button>
      </div>

      <.transition_panel
        :if={@status.transition}
        transition={@status.transition}
        display={@display}
      />

      <p :if={@only_verified != []} id="cardigann-engine-only-verified" class="text-sm opacity-80">
        {gettext("Only verified on the %{engine} engine: %{names}.",
          engine: other_name(@status.active),
          names: Enum.join(@only_verified, ", ")
        )}
      </p>
    </section>
    """
  end

  attr :display, Mydia.TimeDisplay, required: true
  attr :transition, Transition, required: true

  defp transition_panel(assigns) do
    ~H"""
    <div id="cardigann-engine-transition" class="space-y-2">
      <%= case @transition.phase do %>
        <% :failed -> %>
          <div class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <div>
              <p>{@transition.error}</p>
              <p :if={@transition.next_retry_at} class="text-xs opacity-80">
                {gettext("Next attempt at %{time}.",
                  time: format(@transition.next_retry_at, :time, @display)
                )}
              </p>
              <p :if={is_nil(@transition.next_retry_at)} class="text-xs opacity-80">
                {gettext(
                  "Fix the cause, then switch to Built-in and back to Prowlarr-based to try again."
                )}
              </p>
            </div>
            <button
              :if={@transition.next_retry_at}
              id="cardigann-engine-retry"
              type="button"
              phx-click="retry_cardigann_engine"
              class="btn btn-sm"
            >
              {gettext("Retry now")}
            </button>
          </div>
        <% phase when phase in [:fetching, :downloading_precompiled] -> %>
          <progress
            :if={@transition.total}
            class="progress progress-primary w-full"
            value={@transition.bytes}
            max={@transition.total}
          />
          <progress :if={is_nil(@transition.total)} class="progress progress-primary w-full" />
          <p class="text-sm">
            {if phase == :fetching,
              do: gettext("Downloading the Prowlarr-based engine"),
              else: phase_text(phase)} {download_label(@transition)}
          </p>
        <% phase -> %>
          <progress class="progress progress-primary w-full" />
          <p class="text-sm">
            {phase_text(phase)}...
            <span
              id={"cardigann-engine-elapsed-#{phase}"}
              phx-hook=".ElapsedSeconds"
              phx-update="ignore"
              data-since={DateTime.to_iso8601(@transition.phase_started_at)}
            ></span>
          </p>
      <% end %>
      <p class="text-xs opacity-70">
        {gettext("Built-in keeps serving searches until the Prowlarr-based engine is ready.")}
      </p>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ElapsedSeconds">
        export default {
          mounted() { this.tick(); this.timer = setInterval(() => this.tick(), 1000); },
          updated() { this.tick(); },
          destroyed() { clearInterval(this.timer); },
          tick() {
            const since = Date.parse(this.el.dataset.since);
            const s = Math.max(0, Math.round((Date.now() - since) / 1000));
            this.el.textContent = `${s} s`;
          }
        }
      </script>
    </div>
    """
  end

  attr :definition_id, :string, required: true
  attr :active, :atom, required: true

  @doc "One badge saying whether a definition is verified on the active engine."
  def verified_badge(assigns) do
    assigns =
      assign(assigns,
        verification: EngineSupport.verification(assigns.definition_id, assigns.active),
        checked: EngineSupport.verified_on()
      )

    ~H"""
    <%= case @verification do %>
      <% :verified -> %>
        <span
          id={"verified-#{@definition_id}"}
          class="badge badge-xs badge-soft badge-success gap-1"
          title={
            gettext("Search results matched Prowlarr's on the %{engine} engine (checked %{date}).",
              engine: engine_name(@active),
              date: @checked
            )
          }
        >
          <.icon name="hero-check" class="w-3 h-3" />{gettext("Verified")}
        </span>
      <% {:other_only, other} -> %>
        <span
          id={"verified-#{@definition_id}"}
          class="badge badge-xs badge-soft badge-warning"
          title={
            gettext(
              "Search results matched Prowlarr's only on the %{engine} engine (checked %{date}). Change it under How library indexers run.",
              engine: engine_name(other),
              date: @checked
            )
          }
        >
          {gettext("Verified on %{engine} only", engine: engine_name(other))}
        </span>
      <% :unverified -> %>
    <% end %>
    """
  end

  defp selected(%Status{transition: %Transition{target: target}}), do: target
  defp selected(%Status{active: active}), do: active

  @doc false
  def engine_name(:builtin), do: gettext("Built-in")
  def engine_name(:prowlarr), do: gettext("Prowlarr-based")

  defp other_name(:builtin), do: engine_name(:prowlarr)
  defp other_name(:prowlarr), do: engine_name(:builtin)

  defp engine_badge(:builtin), do: nil
  defp engine_badge(:prowlarr), do: gettext("Recommended for private trackers")

  defp engine_subline(:builtin), do: gettext("Mydia's own Cardigann engine.")

  defp engine_subline(:prowlarr),
    do:
      gettext(
        "Prowlarr's Cardigann code, compiled from C# and built into Mydia. No Prowlarr server involved."
      )

  defp engine_pros(:builtin),
    do: [
      gettext("Nothing to download"),
      gettext("No extra memory"),
      gettext("Fastest searches")
    ]

  defp engine_pros(:prowlarr),
    do: [
      gettext("Logs in to private trackers with Prowlarr's own code"),
      gettext("Runs Prowlarr's own engine, so results match Prowlarr closely"),
      gettext("Fails over to a mirror when a tracker's link is down")
    ]

  defp engine_cons(:builtin),
    do: [gettext("Results can differ from Prowlarr's on some trackers")]

  defp engine_cons(:prowlarr),
    do: [
      gettext("One-time download and compile, which needs a lot of memory while it runs"),
      gettext("Uses more memory and is slightly slower per search"),
      gettext("Experimental")
    ]

  defp phase_text(:compiling), do: gettext("Compiling the Prowlarr-based engine")
  defp phase_text(:downloading_precompiled), do: gettext("Downloading the precompiled engine")
  defp phase_text(_phase), do: gettext("Preparing the Prowlarr-based engine")

  defp download_label(%Transition{bytes: nil}), do: ""
  defp download_label(%Transition{bytes: bytes, total: nil}), do: format_mb(bytes)

  defp download_label(%Transition{bytes: bytes, total: total}),
    do: "#{mb(bytes)} / #{format_mb(total)}"

  @doc false
  def format_mb(bytes), do: "#{mb(bytes)} MB"
  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)
end
