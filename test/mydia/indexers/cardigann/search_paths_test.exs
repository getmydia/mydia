defmodule Mydia.Indexers.Cardigann.SearchPathsTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.SearchPaths

  # Site category ids, as a definition's categorymappings declare them.
  @mappings [
    %{"id" => "1", "cat" => "Movies"},
    %{"id" => "2", "cat" => "Movies/HD"},
    %{"id" => "3", "cat" => "TV"}
  ]

  @movies %{path: "/movies", categories: ["1"]}
  @movies_hd %{path: "/movies-hd", categories: ["2"]}
  @tv %{path: "/tv", categories: ["3"]}
  @all %{path: "/all"}
  @page2 %{path: "/all/2"}

  test "a query without categories runs every path" do
    assert SearchPaths.matching([@movies, @tv, @all], [], @mappings) == [@movies, @tv, @all]
  end

  test "paths without categories always run, in definition order" do
    assert SearchPaths.matching([@all, @page2], [2000], @mappings) == [@all, @page2]
  end

  test "a category-scoped path runs only for a matching Torznab category" do
    assert SearchPaths.matching([@movies, @tv, @all], [5000], @mappings) == [@tv, @all]
  end

  test "a parent Torznab category matches a site category mapped to its child" do
    assert SearchPaths.matching([@movies_hd, @tv], [2000], @mappings) == [@movies_hd]
  end

  test "a list starting with ! runs when none of the rest match" do
    not_tv = %{path: "/not-tv", categories: ["!", "3"]}

    assert SearchPaths.matching([not_tv], [2000], @mappings) == [not_tv]
    assert SearchPaths.matching([not_tv, @all], [5000], @mappings) == [@all]
  end

  test "falls back to the first path when nothing matches" do
    assert SearchPaths.matching([@movies, @tv], [8000], @mappings) == [@movies]
  end

  test "site ids given as integers match too" do
    movies = %{path: "/movies", categories: [1]}
    assert SearchPaths.matching([movies, @tv], [2000], @mappings) == [movies]
  end

  test "no paths, no matches" do
    assert SearchPaths.matching([], [2000], @mappings) == []
  end
end
