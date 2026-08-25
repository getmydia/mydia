defmodule MydiaWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :string
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :string, default: nil, doc: "the input class to use over defaults"

  attr :container_class, :string,
    default: "fieldset mb-2",
    doc: "the class for the input's outer container"

  attr :error_class, :string, default: nil, doc: "the input error class to use over defaults"

  attr :hint, :string,
    default: nil,
    doc: "helper text shown below the field; use for examples instead of value-like placeholders"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class={@container_class}>
      <label>
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={@container_class}>
      <label>
        <span :if={@label} class="label mb-1 text-sm font-medium text-base-content/80">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class || "w-full select bg-base-200/50 transition-colors duration-150 focus:bg-base-100",
            @errors != [] && (@error_class || "select-error")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.input_hint :if={@hint} errors={@errors}>{@hint}</.input_hint>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={@container_class}>
      <label>
        <span :if={@label} class="label mb-1 text-sm font-medium text-base-content/80">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class ||
              "w-full textarea bg-base-200/50 transition-colors duration-150 focus:bg-base-100",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.input_hint :if={@hint} errors={@errors}>{@hint}</.input_hint>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class={@container_class}>
      <label>
        <span :if={@label} class="label mb-1 text-sm font-medium text-base-content/80">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input bg-base-200/50 transition-colors duration-150 focus:bg-base-100",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.input_hint :if={@hint} errors={@errors}>{@hint}</.input_hint>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper text shown below a field. Hidden when the field has errors so the
  # error message takes its place rather than stacking.
  attr :errors, :list, default: []
  slot :inner_block, required: true

  defp input_hint(assigns) do
    ~H"""
    <p :if={@errors == []} class="mt-1.5 text-xs text-base-content/50">
      {render_slot(@inner_block)}
    </p>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"
  attr :rest, :global, include: ~w(x-show x-cloak)

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span {@rest} class={[@name, @class]} />
    """
  end

  @doc """
  A 2:3 poster in a hover-scaling figure.

  The hover transform used to be hand-written at every poster grid in the app,
  which is why three of them had it and five did not. It lives here now so a
  new grid gets it by construction.

  The `group` class stays on the caller's own wrapper rather than moving in
  here. Those wrappers differ per page: some are a plain `relative group`, the
  Libraries grid's also carries `phx-click` and a `data-selected` attribute,
  and a presentation component has no business owning them.

  `loading` accepts nil to render no attribute at all. See the note on
  `MydiaWeb.DiscoverComponents.trending_card/1`'s `:loading` attr: lazy-loading
  an above-the-fold poster is what starved the Dashboard's LCP poster under 40
  competing requests.

  ## Examples

      <div class="group">
        <.poster_figure src={poster_url(item)} alt={item.title} class="rounded-t-box">
          <:overlay>
            <span class="badge badge-warning absolute top-2 left-2">8.1</span>
          </:overlay>
        </.poster_figure>
      </div>
  """
  attr :src, :string, default: nil
  attr :alt, :string, required: true
  attr :loading, :string, default: "lazy"
  attr :fallback_icon, :string, default: "hero-film"
  attr :class, :string, default: nil

  slot :overlay, doc: "badges, progress bars and other chrome layered over the poster"

  def poster_figure(assigns) do
    ~H"""
    <figure class={["relative aspect-[2/3] overflow-hidden bg-base-300", @class]}>
      <img
        :if={@src}
        src={@src}
        alt={@alt}
        loading={@loading}
        class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
      />
      <%!-- The fallback carries the same hover transform as the img above. A card
            whose poster is missing is still a link, and a grid where only some
            cards lift on hover reads as broken rather than as a distinction. --%>
      <div
        :if={is_nil(@src)}
        class="w-full h-full flex items-center justify-center group-hover:scale-105 transition-transform duration-300"
      >
        <.icon name={@fallback_icon} class="w-16 h-16 text-base-content/20" />
      </div>
      {render_slot(@overlay)}
    </figure>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Renders a modal dialog using DaisyUI.

  ## Examples

      <.modal id="confirm-modal">
        <:title>Delete Item?</:title>
        <p>Are you sure you want to delete this item?</p>
        <:actions>
          <.button phx-click="cancel">Cancel</.button>
          <.button variant="primary" phx-click="confirm">Confirm</.button>
        </:actions>
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, :any, default: nil

  slot :title
  slot :inner_block, required: true
  slot :actions

  def modal(assigns) do
    ~H"""
    <dialog id={@id} class="modal" open={@show}>
      <div class="modal-box">
        <h3 :if={@title != []} class="font-bold text-lg mb-4">
          {render_slot(@title)}
        </h3>

        <div class="py-4">
          {render_slot(@inner_block)}
        </div>

        <div :if={@actions != []} class="modal-action">
          {render_slot(@actions)}
        </div>

        <%!-- Close button in top right --%>
        <form method="dialog">
          <button
            :if={@on_cancel}
            type="button"
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click={@on_cancel}
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </form>
      </div>

      <%!-- Backdrop --%>
      <form method="dialog" class="modal-backdrop">
        <button :if={@on_cancel} type="button" phx-click={@on_cancel}>close</button>
      </form>
    </dialog>
    """
  end

  @doc """
  Renders a video player component with playback progress tracking.

  Supports both direct play (browser-compatible files) and HLS adaptive streaming.
  Automatically saves and resumes playback position.

  ## Examples

      <.video_player content_type="movie" content_id={@media_item.id} />
      <.video_player content_type="episode" content_id={@episode.id} />
      <.video_player content_type="movie" content_id={@media_item.id} autoplay={true} />
  """
  attr :content_type, :string, required: true, doc: "Type of content: 'movie' or 'episode'"
  attr :content_id, :string, required: true, doc: "ID of the media_item or episode"
  attr :autoplay, :boolean, default: false, doc: "Whether to autoplay the video"
  attr :controls, :boolean, default: true, doc: "Whether to show video controls"
  attr :class, :string, default: "", doc: "Additional CSS classes for the container"
  attr :next_episode, :map, default: nil, doc: "Next episode info map (for TV shows)"
  attr :intro_start, :any, default: nil, doc: "Intro start timestamp in seconds"
  attr :intro_end, :any, default: nil, doc: "Intro end timestamp in seconds"
  attr :credits_start, :any, default: nil, doc: "Credits start timestamp in seconds"

  attr :known_duration, :any,
    default: nil,
    doc: "Known duration in seconds (from FFprobe metadata)"

  def video_player(assigns) do
    ~H"""
    <div
      x-data="videoPlayer()"
      phx-hook="VideoPlayer"
      id={"video-player-#{@content_type}-#{@content_id}"}
      data-content-type={@content_type}
      data-content-id={@content_id}
      data-next-episode={if @next_episode, do: Jason.encode!(@next_episode), else: nil}
      data-intro-start={@intro_start}
      data-intro-end={@intro_end}
      data-credits-start={@credits_start}
      data-known-duration={@known_duration}
      class={["relative bg-black rounded-lg overflow-hidden flex items-center justify-center", @class]}
      x-bind:class="{ 'cursor-none': !controlsVisible }"
    >
      <video
        x-ref="video"
        id={"video-#{@content_type}-#{@content_id}"}
        class="w-full h-auto max-h-[80vh] bg-black object-contain"
        controls={false}
        autoplay={@autoplay}
        muted={@autoplay}
        preload="metadata"
        playsinline
        @play="onPlay"
        @pause="onPause"
        @timeupdate="onTimeUpdate"
        @loadedmetadata="onLoadedMetadata"
        @durationchange="onDurationChange"
        @volumechange="onVolumeChange"
        @waiting="onWaiting"
        @playing="onPlaying"
        @ratechange="onRateChange"
      >
        Your browser does not support video playback.
      </video>

      <%!-- Custom video controls --%>
      <div
        class="controls absolute bottom-0 left-0 right-0 bg-gradient-to-t from-black/80 to-transparent px-4 pb-4 pt-12 transition-opacity duration-300"
        x-show="controlsVisible"
        x-transition:enter="transition ease-out duration-200"
        x-transition:enter-start="opacity-0"
        x-transition:enter-end="opacity-100"
        x-transition:leave="transition ease-in duration-150"
        x-transition:leave-start="opacity-100"
        x-transition:leave-end="opacity-0"
        x-bind:class="{ 'pointer-events-none opacity-0': !controlsVisible }"
      >
        <%!-- Progress bar --%>
        <div class="progress-container mb-4 group cursor-pointer">
          <input
            type="range"
            min="0"
            max="100"
            x-bind:value="progressPercent"
            @input="setProgress($event.target.value)"
            step="0.1"
            class="progress-bar range range-xs range-primary w-full opacity-80 hover:opacity-100 transition-opacity"
          />
        </div>

        <%!-- Control buttons row --%>
        <div class="flex items-center gap-1">
          <%!-- Play/Pause button --%>
          <button
            type="button"
            @click="togglePlay"
            class="p-2 text-white/90 hover:text-white transition-colors"
            aria-label="Play/Pause"
          >
            <.icon x-show="!playing" name="hero-play-solid" class="w-7 h-7" />
            <.icon x-show="playing" x-cloak name="hero-pause-solid" class="w-7 h-7" />
          </button>

          <%!-- Skip backward 10s --%>
          <button
            type="button"
            @click="skipBackward(10)"
            class="p-2 text-white/80 hover:text-white transition-colors"
            aria-label="Skip backward 10 seconds"
          >
            <svg class="w-6 h-6" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12.5 3C17.15 3 21.08 6.03 22.47 10.22L20.1 11C19.05 7.81 16.04 5.5 12.5 5.5C10.54 5.5 8.77 6.22 7.38 7.38L10 10H3V3L5.6 5.6C7.45 4 9.85 3 12.5 3Z" />
              <text
                x="12"
                y="17"
                font-size="7"
                font-weight="600"
                text-anchor="middle"
                fill="currentColor"
              >
                10
              </text>
            </svg>
          </button>

          <%!-- Skip forward 10s --%>
          <button
            type="button"
            @click="skipForward(10)"
            class="p-2 text-white/80 hover:text-white transition-colors"
            aria-label="Skip forward 10 seconds"
          >
            <svg class="w-6 h-6" viewBox="0 0 24 24" fill="currentColor">
              <path d="M11.5 3C6.85 3 2.92 6.03 1.53 10.22L3.9 11C4.95 7.81 7.96 5.5 11.5 5.5C13.46 5.5 15.23 6.22 16.62 7.38L14 10H21V3L18.4 5.6C16.55 4 14.15 3 11.5 3Z" />
              <text
                x="12"
                y="17"
                font-size="7"
                font-weight="600"
                text-anchor="middle"
                fill="currentColor"
              >
                10
              </text>
            </svg>
          </button>

          <%!-- Volume controls - hidden on mobile --%>
          <div class="hidden md:flex items-center gap-1 ml-2">
            <button
              type="button"
              @click="toggleMute"
              class="p-2 text-white/80 hover:text-white transition-colors"
              aria-label="Mute/Unmute"
            >
              <.icon x-show="!muted && volume > 50" name="hero-speaker-wave" class="w-5 h-5" />
              <.icon
                x-show="!muted && volume > 0 && volume <= 50"
                x-cloak
                name="hero-speaker-wave"
                class="w-5 h-5 opacity-70"
              />
              <.icon
                x-show="muted || volume === 0"
                x-cloak
                name="hero-speaker-x-mark"
                class="w-5 h-5"
              />
            </button>
            <input
              type="range"
              min="0"
              max="100"
              x-bind:value="volume"
              @input="setVolume($event.target.value)"
              class="volume-slider range range-xs range-primary w-20 opacity-70 hover:opacity-100 transition-opacity"
            />
          </div>

          <%!-- Time display --%>
          <div class="text-white/80 text-sm font-medium ml-3 hidden sm:block tabular-nums">
            <span x-text="formattedCurrentTime">0:00</span>
            <span class="mx-1 text-white/50">/</span>
            <span x-text="formattedDuration" class="text-white/60">0:00</span>
          </div>

          <%!-- Streaming mode badge --%>
          <div
            x-show="streamingMode"
            x-cloak
            class="hidden sm:flex items-center ml-3"
          >
            <span
              x-text="streamingModeDisplay"
              x-bind:class="{
                'bg-green-500/20 text-green-400 border-green-500/30': streamingMode !== 'transcode',
                'bg-orange-500/20 text-orange-400 border-orange-500/30': streamingMode === 'transcode'
              }"
              class="px-2 py-0.5 text-xs font-medium rounded border"
            ></span>
          </div>

          <div class="flex-1"></div>

          <%!-- Settings button --%>
          <div class="settings-container relative">
            <button
              type="button"
              @click="toggleSettings"
              class="p-2 text-white/80 hover:text-white transition-colors"
              aria-label="Settings"
            >
              <.icon name="hero-cog-6-tooth" class="w-5 h-5" />
            </button>

            <%!-- Settings menu --%>
            <div
              x-show="settingsOpen"
              x-transition:enter="transition ease-out duration-150"
              x-transition:enter-start="opacity-0 scale-95"
              x-transition:enter-end="opacity-100 scale-100"
              x-transition:leave="transition ease-in duration-100"
              x-transition:leave-start="opacity-100 scale-100"
              x-transition:leave-end="opacity-0 scale-95"
              x-cloak
              @click.outside="closeSettings"
              class="absolute bottom-full right-0 mb-2 bg-neutral/95 backdrop-blur-sm rounded-lg shadow-xl min-w-[180px] overflow-hidden"
            >
              <%!-- Playback Speed submenu --%>
              <div class="speed-menu-container">
                <button
                  type="button"
                  @click="toggleSpeedMenu"
                  class="w-full px-4 py-2.5 text-left hover:bg-white/10 flex items-center justify-between text-white transition-colors"
                >
                  <span class="text-sm">Speed</span>
                  <div class="flex items-center gap-2">
                    <span x-text="speedDisplay" class="text-sm text-white/60">Normal</span>
                    <.icon name="hero-chevron-right" class="w-4 h-4 text-white/40" />
                  </div>
                </button>

                <%!-- Speed options submenu --%>
                <div
                  x-show="speedMenuOpen"
                  x-transition
                  x-cloak
                  class="absolute bottom-0 right-full mr-1 bg-neutral/95 backdrop-blur-sm rounded-lg shadow-xl min-w-[120px] overflow-hidden"
                >
                  <button
                    :for={speed <- [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]}
                    type="button"
                    @click={"setSpeed(#{speed})"}
                    class="w-full px-4 py-2 text-left hover:bg-white/10 flex items-center justify-between text-white transition-colors text-sm"
                  >
                    <span>{if speed == 1.0, do: "Normal", else: "#{speed}x"}</span>
                    <.icon
                      x-show={"Math.abs(playbackRate - #{speed}) < 0.01"}
                      name="hero-check"
                      class="w-4 h-4 text-primary"
                    />
                  </button>
                </div>
              </div>

              <%!-- Quality submenu (shown when HLS is active) --%>
              <div
                x-show="hlsLevels.length > 0"
                class="quality-menu-container border-t border-white/10"
              >
                <button
                  type="button"
                  @click="toggleQualityMenu"
                  class="w-full px-4 py-2.5 text-left hover:bg-white/10 flex items-center justify-between text-white transition-colors"
                >
                  <span class="text-sm">Quality</span>
                  <div class="flex items-center gap-2">
                    <span x-text="qualityDisplay" class="text-sm text-white/60">Auto</span>
                    <.icon name="hero-chevron-right" class="w-4 h-4 text-white/40" />
                  </div>
                </button>

                <%!-- Quality options submenu --%>
                <div
                  x-show="qualityMenuOpen"
                  x-transition
                  x-cloak
                  class="absolute bottom-0 right-full mr-1 bg-neutral/95 backdrop-blur-sm rounded-lg shadow-xl min-w-[120px] overflow-hidden"
                >
                  <button
                    type="button"
                    @click="setQuality(-1)"
                    class="w-full px-4 py-2 text-left hover:bg-white/10 flex items-center justify-between text-white transition-colors text-sm"
                  >
                    <span>Auto</span>
                    <.icon
                      x-show="currentHlsLevel === -1"
                      name="hero-check"
                      class="w-4 h-4 text-primary"
                    />
                  </button>
                  <template x-for="(level, index) in hlsLevels">
                    <button
                      type="button"
                      @click="setQuality(index)"
                      class="w-full px-4 py-2 text-left hover:bg-white/10 flex items-center justify-between text-white transition-colors text-sm"
                    >
                      <span x-text="level.height + 'p'"></span>
                      <.icon
                        x-show="currentHlsLevel === index"
                        name="hero-check"
                        class="w-4 h-4 text-primary"
                      />
                    </button>
                  </template>
                </div>
              </div>
            </div>
          </div>

          <%!-- Fullscreen button --%>
          <button
            type="button"
            @click="toggleFullscreen"
            class="p-2 text-white/80 hover:text-white transition-colors"
            aria-label="Toggle Fullscreen"
          >
            <.icon x-show="!isFullscreen" name="hero-arrows-pointing-out" class="w-5 h-5" />
            <.icon x-show="isFullscreen" x-cloak name="hero-arrows-pointing-in" class="w-5 h-5" />
          </button>
        </div>
      </div>

      <%!-- Loading indicator --%>
      <div
        x-show="loading"
        x-transition:enter="transition ease-out duration-200"
        x-transition:enter-start="opacity-0"
        x-transition:enter-end="opacity-100"
        x-transition:leave="transition ease-in duration-150"
        x-transition:leave-start="opacity-100"
        x-transition:leave-end="opacity-0"
        x-cloak
        class="absolute inset-0 flex items-center justify-center bg-black/80 pointer-events-none z-10"
      >
        <div class="flex flex-col items-center gap-3">
          <span class="loading loading-ring loading-lg text-white"></span>
          <p class="text-white/80 text-sm" x-text="loadingMessage">Loading...</p>
        </div>
      </div>

      <%!-- Error message --%>
      <div
        x-show="error"
        x-transition
        x-cloak
        class="absolute inset-0 flex items-center justify-center bg-black/90 z-10"
      >
        <div class="flex flex-col items-center gap-4 text-center px-6">
          <.icon name="hero-exclamation-triangle" class="w-12 h-12 text-error/80" />
          <p x-text="error" class="text-white/90 text-sm max-w-xs">
            Error loading video
          </p>
          <button
            type="button"
            class="px-4 py-2 text-sm text-white/90 hover:text-white bg-white/10 hover:bg-white/20 rounded-lg transition-colors"
            onclick="window.location.reload()"
          >
            Try Again
          </button>
        </div>
      </div>

      <%!-- Skip Intro button --%>
      <div
        x-show="skipIntroVisible"
        x-transition:enter="transition ease-out duration-200"
        x-transition:enter-start="opacity-0 translate-x-4"
        x-transition:enter-end="opacity-100 translate-x-0"
        x-transition:leave="transition ease-in duration-150"
        x-transition:leave-start="opacity-100"
        x-transition:leave-end="opacity-0"
        x-cloak
        class="absolute bottom-24 right-4 z-20"
      >
        <button
          type="button"
          @click="skipIntro"
          class="px-4 py-2 text-sm font-medium text-white bg-white/20 hover:bg-white/30 backdrop-blur-sm rounded-lg border border-white/20 transition-all"
        >
          Skip Intro
        </button>
      </div>

      <%!-- Skip Credits button --%>
      <div
        x-show="skipCreditsVisible"
        x-transition:enter="transition ease-out duration-200"
        x-transition:enter-start="opacity-0 translate-x-4"
        x-transition:enter-end="opacity-100 translate-x-0"
        x-transition:leave="transition ease-in duration-150"
        x-transition:leave-start="opacity-100"
        x-transition:leave-end="opacity-0"
        x-cloak
        class="absolute bottom-24 right-4 z-20"
      >
        <button
          type="button"
          @click="skipCredits"
          class="px-4 py-2 text-sm font-medium text-white bg-white/20 hover:bg-white/30 backdrop-blur-sm rounded-lg border border-white/20 transition-all"
        >
          Skip Credits
        </button>
      </div>

      <%!-- Next Episode card --%>
      <div
        x-show="nextEpisodeVisible"
        x-transition:enter="transition ease-out duration-300"
        x-transition:enter-start="opacity-0 translate-y-4"
        x-transition:enter-end="opacity-100 translate-y-0"
        x-transition:leave="transition ease-in duration-200"
        x-transition:leave-start="opacity-100"
        x-transition:leave-end="opacity-0"
        x-cloak
        class="absolute bottom-24 right-4 z-20"
      >
        <div class="bg-neutral/95 backdrop-blur-sm rounded-xl overflow-hidden max-w-xs shadow-2xl">
          <%!-- Next episode info --%>
          <div class="next-episode-info p-4 flex gap-3">
            <div class="next-episode-poster flex-shrink-0 w-20 h-28 bg-white/10 rounded-lg overflow-hidden">
              <%!-- Poster will be set via JavaScript --%>
            </div>
            <div class="flex-1 min-w-0">
              <p class="text-xs text-white/50 font-medium uppercase tracking-wider mb-1">
                Up Next
              </p>
              <h3 class="next-episode-title text-sm font-medium text-white mb-1 line-clamp-2">
                <%!-- Title will be set via JavaScript --%>
              </h3>
              <p class="next-episode-number text-xs text-white/60">
                <%!-- Episode number will be set via JavaScript --%>
              </p>
            </div>
          </div>

          <%!-- Action buttons --%>
          <div class="px-4 pb-4 flex gap-2">
            <button
              type="button"
              @click="playNextEpisode"
              class="next-episode-play-btn flex-1 px-4 py-2 text-sm font-medium text-white bg-primary hover:bg-primary/90 rounded-lg transition-colors"
            >
              Play Now
            </button>
            <button
              type="button"
              @click="cancelNextEpisode"
              class="next-episode-cancel-btn px-3 py-2 text-sm text-white/70 hover:text-white hover:bg-white/10 rounded-lg transition-colors"
            >
              Cancel
            </button>
          </div>

          <%!-- Auto-play countdown --%>
          <div x-show="countdownVisible" x-transition x-cloak>
            <div class="px-4 pb-3">
              <div class="flex items-center justify-between text-xs text-white/60 mb-2">
                <span>Playing in</span>
                <span x-text="countdownSeconds + 's'" class="countdown-time text-white/80">15s</span>
              </div>
              <div class="countdown-progress-bar w-full h-0.5 bg-white/20 rounded-full overflow-hidden">
                <div
                  x-bind:style="`width: ${countdownProgress}%`"
                  class="countdown-progress h-full bg-primary transition-all duration-100 ease-linear"
                >
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a progress bar overlay for media cards.

  Shows completion percentage for partially watched content.

  ## Examples

      <.progress_bar progress={@progress} />
  """
  attr :progress, :map, required: true, doc: "The progress struct"
  attr :class, :string, default: "", doc: "Additional CSS classes"

  def progress_bar(assigns) do
    ~H"""
    <div
      :if={@progress && @progress.completion_percentage > 0 && @progress.completion_percentage < 90}
      class={["absolute bottom-0 left-0 right-0 h-1 bg-base-300 z-10", @class]}
    >
      <div
        class="h-full bg-primary transition-all duration-300"
        style={"width: #{min(@progress.completion_percentage, 100)}%"}
      >
      </div>
    </div>
    """
  end

  @doc """
  Renders the badge stack overlaid on a media poster's top-right corner.

  Owns that corner so playback state and quality cannot collide. Both badges
  live in one flex column instead of each independently claiming
  `absolute top-2 right-2`.

  Renders nothing when neither a playback badge nor a quality badge applies,
  so no empty positioned container is emitted.

  ## Examples

      <.poster_badges id="poster-badges-1" progress={@progress} quality="1080p" />
  """
  attr :id, :string, default: nil, doc: "DOM id for the container"
  attr :progress, :map, default: nil, doc: "The progress struct, or nil"
  attr :quality, :string, default: nil, doc: "Quality resolution string, or nil"
  attr :class, :string, default: "", doc: "Additional CSS classes"

  def poster_badges(assigns) do
    ~H"""
    <div
      :if={playback_badge?(@progress) or @quality != nil}
      id={@id}
      class={["absolute top-2 right-2 z-10 flex flex-col items-end gap-1", @class]}
    >
      <span :if={continue_badge?(@progress)} class="badge badge-primary badge-sm shadow-md">
        Continue
      </span>

      <span
        :if={watched_badge?(@progress)}
        class="badge badge-success badge-sm shadow-md gap-1"
      >
        <.icon name="hero-check" class="w-3 h-3" /> Watched
      </span>

      <span :if={@quality} class="badge badge-neutral badge-sm shadow-md">{@quality}</span>
    </div>
    """
  end

  # The container gate and the two badge branches are derived from the same
  # predicates, so they can never disagree and leave an empty container.
  defp continue_badge?(%{watched: false, completion_percentage: pct}) when is_number(pct),
    do: pct > 0

  defp continue_badge?(_), do: false

  defp watched_badge?(%{watched: true}), do: true
  defp watched_badge?(_), do: false

  defp playback_badge?(progress),
    do: continue_badge?(progress) or watched_badge?(progress)

  @doc """
  Formats time remaining from progress data.

  Returns a human-readable string like "1h 23m left" or "5m left".
  """
  def format_time_remaining(%{position_seconds: position, duration_seconds: duration})
      when is_integer(position) and is_integer(duration) do
    remaining_seconds = max(duration - position, 0)
    format_duration(remaining_seconds, suffix: " left")
  end

  def format_time_remaining(_), do: nil

  @doc """
  Formats duration in seconds to human-readable format.

  ## Options

    * `:suffix` - Optional suffix to append (default: "")

  ## Examples

      iex> format_duration(3665)
      "1h 1m"

      iex> format_duration(125)
      "2m"

      iex> format_duration(45, suffix: " left")
      "45s left"
  """
  def format_duration(seconds, opts \\ [])

  def format_duration(seconds, opts) when is_integer(seconds) do
    suffix = Keyword.get(opts, :suffix, "")
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      hours > 0 && minutes > 0 -> "#{hours}h #{minutes}m#{suffix}"
      hours > 0 -> "#{hours}h#{suffix}"
      minutes > 0 -> "#{minutes}m#{suffix}"
      true -> "#{secs}s#{suffix}"
    end
  end

  def format_duration(_, _), do: nil

  @doc """
  Label for the blank quality-profile choice.

  That choice stores `nil`, which means "follow the configured default"
  (`Mydia.Indexers.QualityProfileResolver`). When no default is configured,
  `nil` genuinely means no profile, and the label says so.
  """
  @spec default_quality_profile_label(String.t() | nil) :: String.t()
  def default_quality_profile_label(nil), do: "No profile"
  def default_quality_profile_label(name) when is_binary(name), do: "Use default (#{name})"

  @doc """
  Renders a category badge for media items.

  Displays the media category (movie, anime, cartoon, etc.) with appropriate styling.
  Shows an indicator for manual vs auto-detected categories.

  ## Examples

      <.category_badge category="anime_movie" />
      <.category_badge category="tv_show" override={true} />
  """
  attr :category, :string, required: true, doc: "The media category string"
  attr :override, :boolean, default: false, doc: "Whether this is a manual override"
  attr :class, :string, default: "", doc: "Additional CSS classes"
  attr :size, :string, default: "sm", values: ~w(xs sm), doc: "Badge size"

  def category_badge(assigns) do
    ~H"""
    <span
      :if={@category}
      class={[
        "badge inline-flex items-center",
        @override && "gap-1",
        badge_size_class(@size),
        category_badge_class(@category),
        @class
      ]}
      title={category_title(@category, @override)}
    >
      <.icon :if={@override} name="hero-pencil-square" class={icon_size_class(@size)} />
      {category_label(@category)}
    </span>
    """
  end

  defp badge_size_class("xs"), do: "badge-xs"
  defp badge_size_class(_), do: "badge-sm"

  defp icon_size_class("xs"), do: "w-2.5 h-2.5"
  defp icon_size_class(_), do: "w-3 h-3"

  defp category_badge_class("movie"), do: "badge-primary"
  defp category_badge_class("anime_movie"), do: "badge-secondary"
  defp category_badge_class("cartoon_movie"), do: "badge-accent"
  defp category_badge_class("tv_show"), do: "badge-primary"
  defp category_badge_class("anime_series"), do: "badge-secondary"
  defp category_badge_class("cartoon_series"), do: "badge-accent"
  defp category_badge_class(_), do: "badge-ghost"

  defp category_label("movie"), do: "Movie"
  defp category_label("anime_movie"), do: "Anime"
  defp category_label("cartoon_movie"), do: "Cartoon"
  defp category_label("tv_show"), do: "TV"
  defp category_label("anime_series"), do: "Anime"
  defp category_label("cartoon_series"), do: "Cartoon"
  defp category_label(_), do: "Unknown"

  defp category_title(category, true), do: "#{category_label(category)} (Manual override)"
  defp category_title(category, false), do: "#{category_label(category)} (Auto-detected)"

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(MydiaWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(MydiaWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
