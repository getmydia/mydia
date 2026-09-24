defmodule MydiaWeb.MediaBadgeComponents do
  @moduledoc """
  Content rating and show status badges.

  Shared by the library poster card, the media detail page hero and
  `TrendingDetailModal`'s preview, so the badge markup and the show status
  color mapping live in exactly one place instead of drifting across three
  call sites.
  """

  use Phoenix.Component

  alias Mydia.Media.ShowStatus
  alias Mydia.Metadata.Structs.MediaMetadata

  @doc """
  Renders a content rating badge (e.g. "TV-MA", "PG-13").

  Renders nothing when `rating` is `nil` or an empty string.

  ## Example

      <.content_rating_badge rating={item.content_rating} id="rating" />
  """
  attr :rating, :string, default: nil
  attr :id, :string, default: nil
  attr :size, :string, default: "sm", values: ~w(xs sm md)

  def content_rating_badge(assigns) do
    ~H"""
    <span
      :if={@rating not in [nil, ""]}
      id={@id}
      class={["badge badge-outline", badge_size_class(@size), "font-mono"]}
    >
      {@rating}
    </span>
    """
  end

  @doc """
  Renders a TV show status badge with a colored `status` dot.

  Renders nothing when `status` is `nil`.

  ## Example

      <.show_status_badge status={ShowStatus.for_item(item)} id="status" />
  """
  attr :status, :atom, default: nil, values: [nil, :continuing, :ended, :canceled, :upcoming]
  attr :id, :string, default: nil
  attr :size, :string, default: "sm", values: ~w(xs sm md)

  def show_status_badge(assigns) do
    ~H"""
    <span
      :if={@status}
      id={@id}
      data-status={@status}
      class={["badge badge-ghost", badge_size_class(@size), "gap-1"]}
    >
      <span class={["status", status_color_class(@status)]}></span>
      {ShowStatus.label(@status)}
    </span>
    """
  end

  defp badge_size_class("xs"), do: "badge-xs"
  defp badge_size_class("sm"), do: "badge-sm"
  defp badge_size_class("md"), do: "badge-md"

  defp status_color_class(:continuing), do: "status-success"
  defp status_color_class(:ended), do: "status-neutral"
  defp status_color_class(:canceled), do: "status-error"
  defp status_color_class(:upcoming), do: "status-info"

  @doc """
  Formats a release date as `"Mar 4, 2019"`, or `nil` for `nil`.
  """
  @spec format_release_date(Date.t() | nil) :: String.t() | nil
  def format_release_date(nil), do: nil
  def format_release_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")

  @doc """
  The release date carried by fetched metadata: `release_date` for a movie,
  `first_air_date` for a TV show, `nil` otherwise (including `nil` itself).
  """
  @spec release_date(MediaMetadata.t() | term()) :: Date.t() | nil
  def release_date(%MediaMetadata{media_type: :movie, release_date: date}), do: date
  def release_date(%MediaMetadata{media_type: :tv_show, first_air_date: date}), do: date
  def release_date(_metadata), do: nil
end
