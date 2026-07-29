defmodule Mydia.LibrarySearchParityTest do
  @moduledoc """
  Regression tests using real titles from the development database, chosen
  because each one breaks a naive implementation.

  These must pass on **both** SQLite and PostgreSQL. Cross-adapter parity is the
  entire reason this feature uses tokenized `LIKE` rather than FTS5 plus
  `tsvector`, so a failure here means the portability guarantee is gone. Run the
  PostgreSQL pass explicitly:

      ./dev down
      env DATABASE_TYPE=postgres ./dev up -d
      env DATABASE_TYPE=postgres devenv shell -- bash -c \
        'export MIX_ENV=test && mix compile --force && mix ecto.create && mix ecto.migrate && mix test test/mydia/library_search_parity_test.exs'
  """

  use Mydia.DataCase

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.LibrarySearch

  setup do
    show = media_item_fixture(%{type: "tv_show", title: "FROM"})

    episode_fixture(%{
      media_item_id: show.id,
      season_number: 1,
      episode_number: 1,
      title: "Long Day's Journey Into Night"
    })

    media_item_fixture(%{type: "tv_show", title: "In the Grey"})
    media_item_fixture(%{type: "tv_show", title: "Euphoria (US)"})
    media_item_fixture(%{type: "tv_show", title: "Backrooms"})

    %{user: user_fixture(), show: show}
  end

  defp found_titles(results, type) do
    case Enum.find(results.sections, &(&1.type == type)) do
      nil -> []
      section -> Enum.map(section.results, & &1.title)
    end
  end

  test "'from' finds FROM, which is a PostgreSQL english-config stopword", %{user: user} do
    {:ok, results} = LibrarySearch.search(user, "from")

    assert "FROM" in found_titles(results, :tv_show)
  end

  test "'grey' finds In the Grey, whose leading words are stopwords", %{user: user} do
    {:ok, results} = LibrarySearch.search(user, "grey")

    assert "In the Grey" in found_titles(results, :tv_show)
  end

  test "'euphoria us' finds Euphoria (US) despite the punctuation", %{user: user} do
    {:ok, results} = LibrarySearch.search(user, "euphoria us")

    assert "Euphoria (US)" in found_titles(results, :tv_show)
  end

  test "'ackroom' finds Backrooms mid-word, which FTS5 cannot do", %{user: user} do
    {:ok, results} = LibrarySearch.search(user, "ackroom")

    assert "Backrooms" in found_titles(results, :tv_show)
  end

  test "'night journey' finds the episode with the tokens reversed", %{user: user} do
    {:ok, results} = LibrarySearch.search(user, "night journey")

    assert "Long Day's Journey Into Night" in found_titles(results, :episode)
  end

  test "a non-ASCII title is still findable by its ASCII prefix", %{user: user} do
    media_item_fixture(%{type: "movie", title: "parity-title-é'\"😀"})

    {:ok, results} = LibrarySearch.search(user, "parity-title")

    assert "parity-title-é'\"😀" in found_titles(results, :movie)
  end
end
