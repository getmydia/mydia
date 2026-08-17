defmodule Mydia.Library.SelectionScopeTest do
  use Mydia.DataCase, async: true

  import Mydia.SettingsFixtures

  alias Mydia.Library.{ImportGroup, SelectionScope}
  alias Mydia.Repo

  defp seed(lp, n, conf) do
    for i <- 1..n do
      %ImportGroup{}
      |> ImportGroup.changeset(%{
        library_path_id: lp.id,
        anchor_path: "S#{i}",
        cluster_key: "s#{i}-#{conf}",
        file_count: i,
        provider_id: "1",
        min_confidence: conf,
        status: "pending"
      })
      |> Repo.insert!()
    end
  end

  test "page mode selects only the listed ids" do
    lp = library_path_fixture(%{type: "series"})
    [a, b, _c] = seed(lp, 3, 1.0)

    scope =
      lp.id
      |> SelectionScope.new()
      |> SelectionScope.select_page([a.id, b.id])

    assert SelectionScope.selected?(scope, a.id)
    assert SelectionScope.selected?(scope, b.id)
    refute SelectionScope.selected?(scope, Ecto.UUID.generate())
    assert SelectionScope.count(scope) == 2
    assert Repo.aggregate(SelectionScope.to_query(scope), :count) == 2
  end

  test "filter mode selects everything matching without listing ids" do
    lp = library_path_fixture(%{type: "series"})
    seed(lp, 3, 1.0)
    seed(lp, 2, 0.7)

    scope =
      lp.id
      |> SelectionScope.new()
      |> SelectionScope.select_all_matching(%{band: :ready})

    assert Repo.aggregate(SelectionScope.to_query(scope), :count) == 3
    assert SelectionScope.count(scope) == 3
  end

  test "filter mode honours exclusions" do
    lp = library_path_fixture(%{type: "series"})
    [a | _] = seed(lp, 3, 1.0)

    scope =
      lp.id
      |> SelectionScope.new()
      |> SelectionScope.select_all_matching(%{band: :ready})
      |> SelectionScope.toggle(a.id)

    assert Repo.aggregate(SelectionScope.to_query(scope), :count) == 2
    refute SelectionScope.selected?(scope, a.id)
  end

  test "filter mode never puts ids in the query" do
    lp = library_path_fixture(%{type: "series"})
    seed(lp, 3, 1.0)

    scope =
      lp.id
      |> SelectionScope.new()
      |> SelectionScope.select_all_matching(%{band: :ready})

    {sql, params} = Repo.to_sql(:all, SelectionScope.to_query(scope))

    assert is_binary(sql)
    # library_path_id, the band threshold, and nothing per-row.
    assert length(params) <= 3
  end

  test "clear resets to none" do
    lp = library_path_fixture(%{type: "series"})
    [a | _] = seed(lp, 2, 1.0)

    scope =
      lp.id
      |> SelectionScope.new()
      |> SelectionScope.select_page([a.id])
      |> SelectionScope.clear()

    assert SelectionScope.count(scope) == 0
    assert Repo.aggregate(SelectionScope.to_query(scope), :count) == 0
  end
end
