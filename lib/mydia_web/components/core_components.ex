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
        <span
          :if={@label}
          class="label mb-1 text-sm font-medium text-base-content/80 whitespace-normal"
        >{@label}</span>
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
        <span
          :if={@label}
          class="label mb-1 text-sm font-medium text-base-content/80 whitespace-normal"
        >{@label}</span>
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
        <span
          :if={@label}
          class="label mb-1 text-sm font-medium text-base-content/80 whitespace-normal"
        >{@label}</span>
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
  A 2:3 poster in DaisyUI's 3D hover wrapper.

  The hover effect used to be hand-written at every poster grid in the app,
  which is why three of them had it and five did not. It lives here so a new
  grid gets the same interaction by construction. DaisyUI's `hover-3d`
  component requires the content followed by eight empty hover zones; keeping
  that structure here prevents callers from drifting.

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
    <div class="hover-3d grid w-full align-top">
      <figure class={["relative aspect-[2/3] overflow-hidden bg-base-300", @class]}>
        <img
          :if={@src}
          src={@src}
          alt={@alt}
          loading={@loading}
          class="w-full h-full object-cover"
        />
        <div :if={is_nil(@src)} class="w-full h-full flex items-center justify-center">
          <.icon name={@fallback_icon} class="w-16 h-16 text-base-content/20" />
        </div>
        {render_slot(@overlay)}
      </figure>
      <div></div>
      <div></div>
      <div></div>
      <div></div>
      <div></div>
      <div></div>
      <div></div>
      <div></div>
    </div>
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
        <button :if={@on_cancel} type="button" phx-click={@on_cancel}>
          {gettext("close")}
        </button>
      </form>
    </dialog>
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
        {gettext("Continue")}
      </span>

      <span
        :if={watched_badge?(@progress)}
        class="badge badge-success badge-sm shadow-md gap-1"
      >
        <.icon name="hero-check" class="w-3 h-3" /> {gettext("Watched")}
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
    gettext("%{duration} left", duration: format_duration(remaining_seconds))
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

    text =
      cond do
        hours > 0 && minutes > 0 ->
          pgettext("runtime", "%{hours}h %{mins}m", hours: hours, mins: minutes)

        hours > 0 ->
          pgettext("runtime", "%{hours}h", hours: hours)

        minutes > 0 ->
          pgettext("runtime", "%{mins}m", mins: minutes)

        true ->
          pgettext("runtime", "%{secs}s", secs: secs)
      end

    text <> suffix
  end

  def format_duration(_, _), do: nil

  @doc """
  Label for the blank quality-profile choice.

  That choice stores `nil`, which means "follow the configured default"
  (`Mydia.Indexers.QualityProfileResolver`). When no default is configured,
  `nil` genuinely means no profile, and the label says so.
  """
  @spec default_quality_profile_label(String.t() | nil) :: String.t()
  def default_quality_profile_label(nil), do: gettext("No profile")

  def default_quality_profile_label(name) when is_binary(name),
    do: gettext("Use default (%{name})", name: name)

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

  defp category_label("movie"), do: gettext("Movie")
  defp category_label("anime_movie"), do: gettext("Anime")
  defp category_label("cartoon_movie"), do: gettext("Cartoon")
  defp category_label("tv_show"), do: gettext("TV")
  defp category_label("anime_series"), do: gettext("Anime")
  defp category_label("cartoon_series"), do: gettext("Cartoon")
  defp category_label(_), do: gettext("Unknown")

  defp category_title(category, true),
    do: gettext("%{category} (Manual override)", category: category_label(category))

  defp category_title(category, false),
    do: gettext("%{category} (Auto-detected)", category: category_label(category))

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
