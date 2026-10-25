defmodule MydiaWeb.DiscoverLive.Messages do
  @moduledoc """
  Translated option labels and request error text for the Discover page.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Media
  alias MydiaWeb.Live.Helpers.MediaAddHelpers

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

  def sort_options do
    [
      {"popularity.desc", gettext("Most Popular")},
      {"vote_average.desc", gettext("Highest Rated")},
      {"primary_release_date.desc", gettext("Newest First")},
      {"primary_release_date.asc", gettext("Oldest First")}
    ]
  end

  def request_error_message(:duplicate_media),
    do: gettext("That title is already in the library.")

  def request_error_message(:duplicate_request),
    do: gettext("Someone has already requested that title.")

  def request_error_message(:restricted), do: Media.restricted_message()

  def request_error_message(%Ecto.Changeset{} = changeset),
    do:
      gettext("Could not submit the request: %{errors}",
        errors: MediaAddHelpers.format_changeset_errors(changeset)
      )

  def request_error_message(_), do: gettext("Could not submit the request. Please try again.")
end
