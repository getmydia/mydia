defmodule MydiaWeb.MediaLive.Show.FranchiseComponents do
  @moduledoc """
  The franchise strip on a movie's detail page: every movie in the same TMDB
  collection, marked owned or missing.
  """
  use MydiaWeb, :html

  alias Mydia.Metadata.ImageUrl

  @doc """
  Renders the franchise strip.

  The heading is the franchise's own name. TMDB already suffixes these with
  "Collection", so no generic label is added; that also keeps the section from
  reading as one of the user's own collections.
  """
  attr :franchise, :map, required: true
  attr :can_add, :boolean, required: true
  attr :adding_tmdb_id, :integer, default: nil

  def franchise_section(assigns) do
    ~H"""
    <div id="franchise-section" class="mb-6 md:mb-8">
      <div class="flex items-center justify-between gap-3 mb-3">
        <h2 class="text-lg md:text-xl font-semibold truncate">{@franchise.name}</h2>
        <span class={[
          "badge badge-sm flex-shrink-0",
          if(@franchise.owned_count == @franchise.total_count,
            do: "badge-success",
            else: "badge-ghost"
          )
        ]}>
          {@franchise.owned_count} of {@franchise.total_count}
        </span>
      </div>

      <div class="flex gap-3 overflow-x-auto snap-x scroll-smooth pb-2">
        <.franchise_entry
          :for={entry <- @franchise.entries}
          entry={entry}
          can_add={@can_add}
          adding={@adding_tmdb_id == entry.tmdb_id}
        />
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :can_add, :boolean, required: true
  attr :adding, :boolean, default: false

  defp franchise_entry(%{entry: %{current?: true}} = assigns) do
    ~H"""
    <div id={"franchise-entry-#{@entry.tmdb_id}"} class="snap-start flex-shrink-0 w-28">
      <div class="rounded-lg overflow-hidden ring-2 ring-primary">
        <.entry_poster entry={@entry} />
      </div>
      <.entry_caption entry={@entry} />
    </div>
    """
  end

  defp franchise_entry(%{entry: %{in_library?: true}} = assigns) do
    ~H"""
    <.link
      id={"franchise-entry-#{@entry.tmdb_id}"}
      navigate={~p"/media/#{@entry.media_item_id}"}
      class="snap-start flex-shrink-0 w-28 group"
    >
      <div class="rounded-lg overflow-hidden transition duration-200 group-hover:ring-2 group-hover:ring-primary">
        <.entry_poster entry={@entry} />
      </div>
      <.entry_caption entry={@entry} />
    </.link>
    """
  end

  defp franchise_entry(%{can_add: true} = assigns) do
    ~H"""
    <button
      type="button"
      id={"franchise-entry-#{@entry.tmdb_id}"}
      phx-click="add_franchise_movie"
      phx-value-tmdb_id={@entry.tmdb_id}
      disabled={@adding}
      title={"Add #{@entry.title} to your library"}
      class="snap-start flex-shrink-0 w-28 group text-left"
    >
      <div class="relative rounded-lg overflow-hidden">
        <.entry_poster
          entry={@entry}
          class="grayscale opacity-50 transition duration-200 group-hover:opacity-75"
        />
        <div class="absolute inset-0 flex items-center justify-center">
          <span :if={@adding} class="loading loading-spinner loading-md text-primary"></span>
          <.icon
            :if={!@adding}
            name="hero-plus-circle-solid"
            class="w-8 h-8 text-primary opacity-0 transition duration-200 group-hover:opacity-100"
          />
        </div>
      </div>
      <.entry_caption entry={@entry} />
    </button>
    """
  end

  defp franchise_entry(assigns) do
    ~H"""
    <div id={"franchise-entry-#{@entry.tmdb_id}"} class="snap-start flex-shrink-0 w-28">
      <div class="rounded-lg overflow-hidden">
        <.entry_poster entry={@entry} class="grayscale opacity-50" />
      </div>
      <.entry_caption entry={@entry} />
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :class, :string, default: nil

  defp entry_poster(%{entry: %{poster_path: nil}} = assigns) do
    ~H"""
    <div class={[
      "aspect-[2/3] w-full bg-base-300 flex items-center justify-center",
      @class
    ]}>
      <.icon name="hero-film" class="w-8 h-8 text-base-content/30" />
    </div>
    """
  end

  defp entry_poster(assigns) do
    assigns = assign(assigns, :url, ImageUrl.poster_url(assigns.entry.poster_path, "w185"))

    ~H"""
    <img
      src={@url}
      alt={@entry.title}
      loading="lazy"
      class={["aspect-[2/3] w-full object-cover", @class]}
    />
    """
  end

  attr :entry, :map, required: true

  defp entry_caption(assigns) do
    ~H"""
    <div class="mt-1.5">
      <p class="text-xs font-medium leading-tight line-clamp-2">{@entry.title}</p>
      <p :if={@entry.year} class="text-xs text-base-content/60">{@entry.year}</p>
    </div>
    """
  end
end
