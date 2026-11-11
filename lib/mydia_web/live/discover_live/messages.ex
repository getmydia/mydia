defmodule MydiaWeb.DiscoverLive.Messages do
  @moduledoc """
  Translated option labels and request error text for the Discover page.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias MydiaWeb.Live.Helpers.MediaAddHelpers

  def page_subtitle(:movie), do: gettext("Find new movies to add to your library")
  def page_subtitle(:tv_show), do: gettext("Find new TV shows to add to your library")
  def page_subtitle(:person), do: gettext("Find people and the titles they appear in")

  def search_placeholder(:movie), do: gettext("Search for a movie to add")
  def search_placeholder(:tv_show), do: gettext("Search for a show to add")
  def search_placeholder(:person), do: gettext("Search people")

  def movie_categories do
    [
      {:trending, gettext("Trending")},
      {:popular, gettext("Popular")},
      {:upcoming, gettext("Upcoming")},
      {:now_playing, gettext("Now Playing")}
    ]
  end

  def tv_categories do
    [
      {:trending, gettext("Trending")},
      {:popular, gettext("Popular")},
      {:on_the_air, gettext("On The Air")},
      {:airing_today, gettext("Airing Today")}
    ]
  end

  # TMDB's TV discover sorts by first_air_date and silently ignores
  # primary_release_date, falling back to popularity (#1381).
  def sort_options(media_type) do
    date = if media_type == :tv_show, do: "first_air_date", else: "primary_release_date"

    [
      {"popularity.desc", gettext("Most Popular")},
      {"vote_average.desc", gettext("Highest Rated")},
      {"#{date}.desc", gettext("Newest First")},
      {"#{date}.asc", gettext("Oldest First")}
    ]
  end

  def request_error_message(:duplicate_media),
    do: gettext("That title is already in the library.")

  def request_error_message(:duplicate_request),
    do: gettext("Someone has already requested that title.")

  def request_error_message(:restricted), do: MydiaWeb.OperationErrors.restricted_message()

  def request_error_message(%Ecto.Changeset{} = changeset),
    do:
      gettext("Could not submit the request: %{errors}",
        errors: MediaAddHelpers.format_changeset_errors(changeset)
      )

  def request_error_message(_), do: gettext("Could not submit the request. Please try again.")
end
