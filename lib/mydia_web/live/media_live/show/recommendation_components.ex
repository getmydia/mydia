defmodule MydiaWeb.MediaLive.Show.RecommendationComponents do
  @moduledoc """
  The recommendations strip on a media detail page.

  An adapter rather than a renderer, like its sibling `FranchiseComponents`:
  it maps this page's assigns onto `DiscoverComponents.media_rail/1` and
  delegates, so a recommendation and a franchise entry draw the same card.

  It exists because the rail has two call sites in `show.html.heex`. A TV show
  renders it above the episode list, a movie below the file list, and neither
  should have to repeat eleven attributes or restate the collapse rule.
  """
  use MydiaWeb, :html

  alias MydiaWeb.DiscoverComponents

  @doc """
  Renders the recommendations rail.

  Collapsible only on TV shows, where it stays collapsed until the user opens
  it so a long episode list is not pushed under a strip of other titles. On a
  movie `media_rail/1` computes `open? = not collapsible or expanded`, so the
  rail renders open there and `expanded` is ignored.
  """
  attr :media_item, :map, required: true
  attr :items, :list, required: true
  attr :expanded, :boolean, required: true
  attr :current_user, :map, required: true
  attr :adding_ids, MapSet, required: true
  attr :requesting_item_id, :string, default: nil
  attr :can_add, :boolean, required: true

  def recommendations_section(assigns) do
    tv_show? = assigns.media_item.type == "tv_show"

    assigns =
      assigns
      |> assign(:tv_show?, tv_show?)
      |> assign(:media_type, if(tv_show?, do: :tv_show, else: :movie))

    ~H"""
    <DiscoverComponents.media_rail
      id="recommendations-rail"
      collapsible={@tv_show?}
      expanded={@expanded}
      toggle_event="toggle_recommendations"
      items={@items}
      media_type={@media_type}
      current_user={@current_user}
      adding_ids={@adding_ids}
      requesting_item_id={@requesting_item_id}
      can_add={@can_add}
      on_select={nil}
      add_event="add_recommendation"
      request_event="request_recommendation"
    />
    """
  end
end
