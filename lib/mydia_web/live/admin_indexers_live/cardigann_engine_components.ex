defmodule MydiaWeb.AdminIndexersLive.CardigannEngineComponents do
  @moduledoc """
  The Cardigann engine picker on the Indexers tab and the per-tracker
  "verified on" badges. Rendering only; `MydiaWeb.AdminIndexersLive.Index`
  handles the events.

  The copy is qualitative on purpose: measured figures change with every bench
  run and live in the docs.
  """
  use MydiaWeb, :html

  alias Mydia.Indexers.Cardigann.EngineSupport
  alias Mydia.Indexers.Cardigann.EngineSwitcher.{Status, Transition}

  @engines [
    %{
      id: :builtin,
      name: "Built-in",
      pros: ["Nothing to download", "No extra memory", "Fastest searches"],
      cons: ["Results can differ from Prowlarr's on some trackers"]
    },
    %{
      id: :prowlarr,
      name: "Prowlarr",
      pros: [
        "Runs Prowlarr's own engine, so results match Prowlarr closely",
        "Fails over to a mirror when a tracker's link is down"
      ],
      cons: [
        "One-time download and compile, which needs a lot of memory while it runs",
        "Uses more memory and is slightly slower per search",
        "Experimental"
      ]
    }
  ]

  @docs_url "https://docs.mydia.dev/latest/using/how-to/cardigann-indexers/#using-prowlarrs-engine-experimental"

  attr :status, Status, required: true
  attr :cache_bytes, :integer, required: true

  attr :only_verified, :list,
    required: true,
    doc: "names of library trackers verified only on the inactive engine"

  def engine_section(assigns) do
    assigns = assign(assigns, engines: @engines, docs_url: @docs_url)

    ~H"""
    <section id="cardigann-engine" class="space-y-3">
      <div class="flex items-center gap-2">
        <.icon name="hero-cpu-chip" class="w-4 h-4 opacity-70" />
        <h3 class="font-semibold">Indexer library engine</h3>
        <.env_lock_badge :if={@status.locked} tip="Set by CARDIGANN_ENGINE" />
        <a href={@docs_url} target="_blank" class="link link-hover text-xs opacity-70 ml-auto">
          How they compare
        </a>
      </div>

      <.form for={%{}} id="cardigann-engine-form" phx-change="switch_cardigann_engine">
        <div class="grid gap-3 sm:grid-cols-2">
          <label
            :for={engine <- @engines}
            class={[
              "card card-border bg-base-100 cursor-pointer transition-colors hover:border-primary/60",
              engine.id == selected(@status) && "border-primary",
              @status.locked && "cursor-not-allowed opacity-70"
            ]}
          >
            <div class="card-body p-4 gap-2">
              <div class="flex items-center gap-2">
                <input
                  type="radio"
                  name="engine"
                  id={"cardigann-engine-#{engine.id}"}
                  value={engine.id}
                  class="radio radio-primary radio-sm"
                  checked={engine.id == selected(@status)}
                  disabled={@status.locked}
                />
                <span class="font-medium">{engine.name}</span>
                <span :if={engine.id == @status.active} class="badge badge-success badge-sm">
                  Active
                </span>
                <span
                  :if={@status.transition && engine.id == @status.transition.target}
                  class="badge badge-info badge-sm"
                >
                  Switching
                </span>
              </div>
              <ul class="text-sm space-y-1">
                <li :for={pro <- engine.pros} class="flex gap-2">
                  <.icon name="hero-plus-circle" class="w-4 h-4 text-success shrink-0" />{pro}
                </li>
                <li :for={con <- engine.cons} class="flex gap-2 opacity-80">
                  <.icon name="hero-minus-circle" class="w-4 h-4 text-warning shrink-0" />{con}
                </li>
              </ul>
            </div>
          </label>
        </div>
      </.form>

      <.transition_panel :if={@status.transition} transition={@status.transition} />

      <p :if={@only_verified != []} id="cardigann-engine-only-verified" class="text-sm opacity-80">
        Only verified on the {other_name(@status.active)} engine: {Enum.join(@only_verified, ", ")}.
      </p>

      <button
        :if={@status.active == :builtin and is_nil(@status.transition) and @cache_bytes > 0}
        id="cardigann-engine-remove-cache"
        type="button"
        phx-click="remove_cardigann_engine_cache"
        class="btn btn-ghost btn-xs"
      >
        <.icon name="hero-trash" class="w-3 h-3" />
        Remove cached Prowlarr engine ({format_mb(@cache_bytes)})
      </button>
    </section>
    """
  end

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
                Next attempt at {Calendar.strftime(@transition.next_retry_at, "%H:%M")} UTC.
              </p>
              <p :if={is_nil(@transition.next_retry_at)} class="text-xs opacity-80">
                Fix the cause, then switch to Built-in and back to Prowlarr to try again.
              </p>
            </div>
            <button
              :if={@transition.next_retry_at}
              id="cardigann-engine-retry"
              type="button"
              phx-click="retry_cardigann_engine"
              class="btn btn-sm"
            >
              Retry now
            </button>
          </div>
        <% :fetching -> %>
          <progress
            :if={@transition.total}
            class="progress progress-primary w-full"
            value={@transition.bytes}
            max={@transition.total}
          />
          <progress :if={is_nil(@transition.total)} class="progress progress-primary w-full" />
          <p class="text-sm">
            Downloading the Prowlarr engine {download_label(@transition)}
          </p>
        <% phase -> %>
          <progress class="progress progress-primary w-full" />
          <p class="text-sm">
            {if phase == :compiling, do: "Compiling", else: "Preparing"} the Prowlarr engine...
            <span
              id={"cardigann-engine-elapsed-#{phase}"}
              phx-hook=".ElapsedSeconds"
              phx-update="ignore"
              data-since={DateTime.to_iso8601(@transition.phase_started_at)}
            ></span>
          </p>
      <% end %>
      <p class="text-xs opacity-70">
        Built-in keeps serving searches until the Prowlarr engine is ready.
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

  @doc "\"Built-in\" / \"Prowlarr\" badges for the engines a definition was verified on."
  def verified_badges(assigns) do
    assigns =
      assign(assigns,
        engines: EngineSupport.verified_engines(assigns.definition_id),
        tip: "Verified against Prowlarr's results on #{EngineSupport.verified_on()}"
      )

    ~H"""
    <span
      :for={engine <- @engines}
      id={"verified-#{@definition_id}-#{engine}"}
      class={[
        "badge badge-xs gap-1 tooltip",
        if(engine == @active, do: "badge-primary", else: "badge-outline")
      ]}
      data-tip={@tip}
    >
      <.icon name="hero-check" class="w-3 h-3" />{engine_name(engine)}
    </span>
    """
  end

  defp selected(%Status{transition: %Transition{target: target}}), do: target
  defp selected(%Status{active: active}), do: active

  defp engine_name(:builtin), do: "Built-in"
  defp engine_name(:prowlarr), do: "Prowlarr"

  defp other_name(:builtin), do: engine_name(:prowlarr)
  defp other_name(:prowlarr), do: engine_name(:builtin)

  defp download_label(%Transition{bytes: nil}), do: ""
  defp download_label(%Transition{bytes: bytes, total: nil}), do: format_mb(bytes)

  defp download_label(%Transition{bytes: bytes, total: total}),
    do: "#{mb(bytes)} / #{format_mb(total)}"

  @doc false
  def format_mb(bytes), do: "#{mb(bytes)} MB"
  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)
end
