defmodule MydiaWeb.PersonComponents do
  @moduledoc """
  Components for TMDB people: the person popup, opened from a cast member or a
  People search result.

  The popup is driven by `MydiaWeb.Live.Helpers.PersonModal` on the host.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents, only: [icon: 1]

  alias Mydia.Metadata.ImageUrl
  alias Mydia.Metadata.Structs.{Person, PersonCredit}
  alias Phoenix.LiveView.JS

  # Posters shown per section before "Show all".
  @initial_visible 12

  @doc """
  Renders the person popup.

  Below the title dialog (`z-[999]`) so a title opened from here stacks on top.

  ## Events

  Emits `close_person`, `retry_person` and `show_details` (with `phx-value-id`
  and `phx-value-type` of `"movie"` or `"tv_show"`) to the host.

  ## `escape_enabled`

  Every caller must pass it, with no default, for the same reason as
  `TrendingDetailModal`'s `config_open`: `phx-window-keydown` is not scoped by
  stacking, so it must be false whenever the title dialog or the configure
  dialog is open above this one, or one Escape closes both layers.
  """
  attr :id, :string, required: true
  attr :person, :any, default: nil, doc: "a `Person`, or nil while loading or on error"
  attr :stub, :map, default: nil, doc: "`%{id, name, profile_path}` from the click"
  attr :titles, :list, default: [], doc: "enriched `SearchResult`s, the viewer's visible credits"
  attr :loading, :boolean, default: false
  attr :error, :any, default: nil
  attr :escape_enabled, :boolean, required: true

  def person_modal(assigns) do
    open? = assigns.person != nil or assigns.stub != nil
    person = assigns.person

    assigns =
      assigns
      |> assign(:open, open?)
      |> assign(:name, (person && person.name) || (assigns.stub && assigns.stub.name))
      |> assign(
        :profile_path,
        (person && person.profile_path) || (assigns.stub && assigns.stub[:profile_path])
      )
      |> assign(:owned_count, Enum.count(assigns.titles, &Map.get(&1, :in_library, false)))
      |> assign(:movies, credit_rows(person, :movie_credits, assigns.titles))
      |> assign(:shows, credit_rows(person, :tv_credits, assigns.titles))

    ~H"""
    <dialog
      id={@id}
      class="modal z-[998]"
      open={@open}
      phx-window-keydown={@open && @escape_enabled && "close_person"}
      phx-key="Escape"
    >
      <%= if @open do %>
        <div class="modal-box max-w-4xl w-11/12 max-h-[90vh] p-0 flex flex-col overflow-hidden">
          <div
            id="person-modal-header"
            class="relative p-4 md:p-6 bg-gradient-to-br from-base-300 to-base-100 flex gap-4 md:gap-6 shrink-0"
          >
            <button
              id="person-modal-close"
              type="button"
              phx-click="close_person"
              aria-label={gettext("Close")}
              class="btn btn-circle btn-ghost btn-sm absolute top-3 right-3 z-10"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>

            <%= if @profile_path do %>
              <img
                src={ImageUrl.profile_url(@profile_path, "h632")}
                alt={@name}
                class="w-28 h-40 md:w-40 md:h-56 rounded-xl shadow-lg object-cover shrink-0"
              />
            <% else %>
              <div class="w-28 h-40 md:w-40 md:h-56 rounded-xl bg-base-300 flex items-center justify-center shrink-0">
                <.icon name="hero-user" class="w-12 h-12 text-base-content/30" />
              </div>
            <% end %>

            <div class="flex flex-col gap-2 min-w-0">
              <h2 id="person-modal-name" class="text-2xl md:text-3xl font-bold pr-10">{@name}</h2>
              <%= if @person do %>
                <p
                  :if={facts_line(@person, length(@movies) + length(@shows)) != ""}
                  class="text-sm text-base-content/70"
                >
                  {facts_line(@person, length(@movies) + length(@shows))}
                </p>
                <div :if={@owned_count > 0} class="flex gap-2 mt-1">
                  <span id="person-owned-count" class="badge badge-success badge-soft">
                    {ngettext("%{count} in your library", "%{count} in your library", @owned_count)}
                  </span>
                </div>
                <%= if @person.biography do %>
                  <div id="person-bio-block">
                    <p
                      id="person-bio"
                      class="text-base-content/80 leading-relaxed mt-2 line-clamp-4 whitespace-pre-line"
                    >
                      {@person.biography}
                    </p>
                    <button
                      id="person-bio-toggle"
                      type="button"
                      phx-click={
                        JS.toggle_class("line-clamp-4", to: "#person-bio")
                        |> JS.toggle_class("hidden", to: "#person-bio-toggle > span")
                      }
                      class="link link-hover text-sm"
                    >
                      <span>{gettext("Read more")}</span>
                      <span class="hidden">{gettext("Show less")}</span>
                    </button>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>

          <div id="person-modal-body" class="flex-1 overflow-y-auto p-4 md:p-6 space-y-8">
            <%= cond do %>
              <% @error -> %>
                <div id="person-modal-error" class="alert alert-error">
                  <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                  <span>{gettext("Could not load details for %{name}.", name: @name)}</span>
                  <button
                    id="person-modal-retry"
                    type="button"
                    phx-click="retry_person"
                    class="btn btn-sm"
                  >
                    {gettext("Try again")}
                  </button>
                </div>
              <% @loading or is_nil(@person) -> %>
                <div id="person-modal-loading" class="flex items-center justify-center py-12">
                  <span class="loading loading-spinner loading-lg"></span>
                  <span class="ml-3 text-base-content/70">{gettext("Loading details...")}</span>
                </div>
              <% true -> %>
                <.credit_section
                  :if={@movies != []}
                  id="person-movies"
                  type="movie"
                  heading={gettext("Movies")}
                  rows={@movies}
                />
                <.credit_section
                  :if={@shows != []}
                  id="person-shows"
                  type="tv_show"
                  heading={gettext("Shows")}
                  rows={@shows}
                />
            <% end %>
          </div>
        </div>
      <% end %>
    </dialog>
    """
  end

  @doc """
  Renders one cast member as a centered avatar card (the title preview layout).

  With `event` nil it is the plain, non-interactive card. With `event` set, a
  member that has a `tmdb_person_id` becomes a button that emits `event` with
  `phx-value-id`, `phx-value-name` and `phx-value-profile_path`, the payload
  `MydiaWeb.Live.Helpers.PersonModal.open/2` expects. A member without an id
  renders greyed with a tooltip, since there is nobody to open.

  A host that passes `event` must handle it.

  `layout` is `"card"` (the default, the title preview's avatar card) or
  `"row"`, a small avatar beside "name as character", the media page's compact
  cast panel.

  `id_prefix` names the button's DOM id, `"<id_prefix>-<tmdb_person_id>"`. A page
  that renders its own cast next to the title preview's (the media page) can
  show one actor in both, so it must pass a prefix of its own or the two
  buttons share an id.
  """
  attr :member, :any,
    required: true,
    doc: "anything with `name`, `character`, `profile_path` and `tmdb_person_id`"

  attr :event, :string, default: nil, doc: "the host event to emit on click, nil for no link"
  attr :layout, :string, default: "card", values: ["card", "row"]
  attr :id_prefix, :string, default: "cast-person"

  def cast_person(assigns) do
    member = assigns.member
    person_id = Map.get(member, :tmdb_person_id)

    assigns =
      assigns
      |> assign(:person_id, person_id)
      |> assign(:profile_path, Map.get(member, :profile_path))
      |> assign(:character, Map.get(member, :character))

    ~H"""
    <%= cond do %>
      <% is_nil(@event) -> %>
        <div class={cast_person_class(@layout)}>
          <.cast_person_body
            member={@member}
            profile_path={@profile_path}
            character={@character}
            layout={@layout}
          />
        </div>
      <% is_nil(@person_id) -> %>
        <div
          class={[cast_person_class(@layout), "opacity-60 tooltip"]}
          data-tip={gettext("No linked profile yet")}
        >
          <.cast_person_body
            member={@member}
            profile_path={@profile_path}
            character={@character}
            layout={@layout}
          />
        </div>
      <% true -> %>
        <button
          id={"#{@id_prefix}-#{@person_id}"}
          type="button"
          phx-click={@event}
          phx-value-id={@person_id}
          phx-value-name={@member.name}
          phx-value-profile_path={@profile_path}
          class={[cast_person_class(@layout), "group cursor-pointer"]}
        >
          <.cast_person_body
            member={@member}
            profile_path={@profile_path}
            character={@character}
            layout={@layout}
            hover
          />
        </button>
    <% end %>
    """
  end

  defp cast_person_class("row"), do: "flex w-full items-center gap-2 text-left"
  defp cast_person_class(_card), do: "text-center"

  attr :member, :any, required: true
  attr :profile_path, :string, default: nil
  attr :character, :string, default: nil
  attr :layout, :string, required: true
  attr :hover, :boolean, default: false

  defp cast_person_body(%{layout: "row"} = assigns) do
    ~H"""
    <%= if @profile_path do %>
      <img
        src={ImageUrl.profile_url(@profile_path)}
        alt={@member.name}
        class={[
          "w-6 h-6 rounded-full object-cover shrink-0",
          @hover && "transition group-hover:ring-2 group-hover:ring-primary"
        ]}
      />
    <% else %>
      <div class={[
        "w-6 h-6 rounded-full bg-base-300 flex items-center justify-center shrink-0",
        @hover && "transition group-hover:ring-2 group-hover:ring-primary"
      ]}>
        <.icon name="hero-user" class="w-3 h-3 text-base-content/30" />
      </div>
    <% end %>
    <span class="text-sm min-w-0">
      <span class={["font-medium", @hover && "group-hover:text-primary"]}>{@member.name}</span>
      <span :if={@character} class="text-base-content/60 text-xs">
        {gettext("as %{character}", character: @character)}
      </span>
    </span>
    """
  end

  defp cast_person_body(assigns) do
    ~H"""
    <%= if @profile_path do %>
      <img
        src={ImageUrl.profile_url(@profile_path)}
        alt={@member.name}
        class={[
          "w-16 h-16 md:w-20 md:h-20 rounded-full object-cover mx-auto mb-2",
          @hover && "transition group-hover:ring-2 group-hover:ring-primary"
        ]}
      />
    <% else %>
      <div class={[
        "w-16 h-16 md:w-20 md:h-20 rounded-full bg-base-300 flex items-center justify-center mx-auto mb-2",
        @hover && "transition group-hover:ring-2 group-hover:ring-primary"
      ]}>
        <.icon name="hero-user" class="w-8 h-8 text-base-content/30" />
      </div>
    <% end %>
    <p class="text-sm font-medium line-clamp-1">{@member.name}</p>
    <%= if @character do %>
      <p class="text-xs text-base-content/60 line-clamp-1">{@character}</p>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :type, :string, required: true
  attr :heading, :string, required: true
  attr :rows, :list, required: true

  # "All / In library" and "Show all" are client-side classes on the section, so
  # neither costs a server round trip. Selecting "In library" also expands the
  # section, since the owned titles can sit past the first twelve; an expanded
  # section hides "Show all", and the toggle marks whichever filter is on.
  defp credit_section(assigns) do
    assigns =
      assigns
      |> assign(:total, length(assigns.rows))
      |> assign(:any_owned, Enum.any?(assigns.rows, & &1.owned))

    ~H"""
    <div id={@id} class="group/credits">
      <div class="flex items-baseline justify-between mb-3">
        <h3 class="text-lg font-semibold">
          {@heading}
          <span class="text-base-content/50 font-normal text-sm">{@total}</span>
        </h3>
        <div :if={@any_owned} class="join">
          <button
            id={"#{@id}-filter-all"}
            type="button"
            phx-click={JS.remove_class("owned-only", to: "##{@id}")}
            class="btn btn-xs join-item group-[:not(.owned-only)]/credits:btn-active"
          >
            {gettext("All")}
          </button>
          <button
            id={"#{@id}-filter-owned"}
            type="button"
            phx-click={JS.add_class("owned-only expanded", to: "##{@id}")}
            class="btn btn-xs join-item group-[.owned-only]/credits:btn-active"
          >
            {gettext("In library")}
          </button>
        </div>
      </div>
      <div class="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-6 gap-3">
        <%= for {row, index} <- Enum.with_index(@rows) do %>
          <button
            id={"person-credit-#{@type}-#{row.id}"}
            type="button"
            phx-click="show_details"
            phx-value-id={row.id}
            phx-value-type={@type}
            data-extra={index >= initial_visible() && "true"}
            class={[
              "text-left group",
              index >= initial_visible() && "group-[:not(.expanded)]/credits:hidden",
              not row.owned && "group-[.owned-only]/credits:hidden"
            ]}
          >
            <div class="relative aspect-[2/3] rounded-lg bg-base-300 overflow-hidden">
              <img
                :if={row.poster_path}
                src={ImageUrl.poster_url(row.poster_path, "w342")}
                alt=""
                loading="lazy"
                class="w-full h-full object-cover transition group-hover:scale-105"
              />
              <span :if={row.owned} class="badge badge-success badge-xs absolute top-1 right-1">
                <.icon name="hero-check" class="w-3 h-3" />
              </span>
            </div>
            <p class="text-sm mt-1 line-clamp-1">{row.title}</p>
            <p class="text-xs text-base-content/60 line-clamp-1">{row.subtitle}</p>
          </button>
        <% end %>
      </div>
      <button
        :if={@total > initial_visible()}
        id={"#{@id}-show-all"}
        type="button"
        phx-click={JS.add_class("expanded", to: "##{@id}")}
        class="btn btn-ghost btn-sm mt-2 group-[.expanded]/credits:hidden"
      >
        {gettext("Show all %{count}", count: @total)}
      </button>
    </div>
    """
  end

  defp initial_visible, do: @initial_visible

  # One row per credit the viewer may see. A credit whose title is absent from
  # `titles` was refused by the remote filter and is dropped, not shown bare.
  defp credit_rows(nil, _field, _titles), do: []

  defp credit_rows(%Person{} = person, field, titles) do
    by_key = Map.new(titles, &{{&1.media_type, to_string(&1.provider_id)}, &1})

    for %PersonCredit{} = credit <- Map.fetch!(person, field),
        title = Map.get(by_key, {credit.media_type, Integer.to_string(credit.tmdb_id)}) do
      %{
        id: credit.tmdb_id,
        title: credit.title,
        poster_path: credit.poster_path,
        owned: Map.get(title, :in_library, false),
        subtitle: credit_subtitle(credit)
      }
    end
  end

  defp credit_subtitle(%PersonCredit{media_type: :tv_show, episode_count: count} = credit)
       when is_integer(count) and count > 0 do
    join_present([
      credit.year,
      ngettext("%{count} ep", "%{count} eps", count)
    ])
  end

  defp credit_subtitle(%PersonCredit{} = credit),
    do: join_present([credit.year, credit.character])

  defp facts_line(%Person{} = person, credit_count) do
    born =
      cond do
        person.birthday && person.place_of_birth ->
          gettext("Born %{year} in %{place}",
            year: person.birthday.year,
            place: person.place_of_birth
          )

        person.birthday ->
          gettext("Born %{year}", year: person.birthday.year)

        person.place_of_birth ->
          gettext("Born in %{place}", place: person.place_of_birth)

        true ->
          nil
      end

    credits =
      if credit_count > 0, do: ngettext("%{count} credit", "%{count} credits", credit_count)

    join_present([person.known_for_department, born, credits])
  end

  defp join_present(parts) do
    parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end
end
