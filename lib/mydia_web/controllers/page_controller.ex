defmodule MydiaWeb.PageController do
  use MydiaWeb, :controller
  alias Mydia.Media

  def home(conn, _params) do
    movie_count = Media.count_movies(conn.assigns.current_scope)
    tv_show_count = Media.count_tv_shows(conn.assigns.current_scope)

    render(conn, :home, movie_count: movie_count, tv_show_count: tv_show_count)
  end
end
