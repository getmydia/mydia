defmodule Mydia.Library.SelectionScopeTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.SelectionScope
  alias Mydia.Repo

  # One candidate per anchor key, so "n groups" and "n candidates" coincide --
  # every assertion below is phrased in terms of groups (anchor keys), which
  # is what SelectionScope actually selects.
  defp seed(lp, n, conf) do
    for i <- 1..n do
      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "s#{i}-#{conf}",
        relative_path: "s#{i}-#{conf}/file.mkv",
        provider_id: "1",
        provider_type: "tvdb",
        confidence: conf
      })
    end
  end

  defp query_ids(scope) do
    scope |> SelectionScope.to_query() |> Repo.all() |> Enum.map(& &1.anchor_key) |> MapSet.new()
  end

  test "page mode selects only the listed anchor keys" do
    lp = library_path_fixture(%{type: "series"})
    [a, b, _c] = seed(lp, 3, 1.0)

    scope =
      lp.id
      |> SelectionScope.new()
      |> SelectionScope.select_page([a.anchor_key, b.anchor_key])

    assert SelectionScope.selected?(scope, a.anchor_key)
    assert SelectionScope.selected?(scope, b.anchor_key)
    refute SelectionScope.selected?(scope, "does-not-exist")
    assert SelectionScope.count(scope) == 2
    assert Repo.aggregate(SelectionScope.to_query(scope) |> Ecto.Query.subquery(), :count) == 2
  end

  test "filter mode selects everything matching without listing keys" do
    lp = library_path_fixture(%{type: "series"})
    seed(lp, 3, 1.0)
    seed(lp, 2, 0.7)

    scope =
      lp.id
      |> SelectionScope.new()
      |> SelectionScope.select_all_matching(%{band: :ready})

    assert Repo.aggregate(SelectionScope.to_query(scope) |> Ecto.Query.subquery(), :count) == 3
    assert SelectionScope.count(scope) == 3
  end

  test "filter mode honours exclusions" do
    lp = library_path_fixture(%{type: "series"})
    [a | _] = seed(lp, 3, 1.0)

    scope =
      lp.id
      |> SelectionScope.new()
      |> SelectionScope.select_all_matching(%{band: :ready})
      |> SelectionScope.toggle(a.anchor_key)

    assert Repo.aggregate(SelectionScope.to_query(scope) |> Ecto.Query.subquery(), :count) == 2
    refute SelectionScope.selected?(scope, a.anchor_key)
  end

  test "filter mode's parameter count does not grow with how many rows match" do
    lp = library_path_fixture(%{type: "series"})
    seed(lp, 3, 1.0)

    scope =
      lp.id
      |> SelectionScope.new()
      |> SelectionScope.select_all_matching(%{band: :ready})

    {sql, small_params} = Repo.to_sql(:all, SelectionScope.to_query(scope))
    assert is_binary(sql)

    # Prove it's a shape property, not an artifact of the 3-row fixture: adding
    # hundreds more matching rows (well past `max_id_binds/0`) must not change
    # the parameter count at all, because `to_query/1`'s `:filter` clause never
    # inspects matching rows to build the query in the first place. A distinct
    # confidence (still >= the :ready threshold) keeps anchor keys unique
    # against the first `seed/3` call above.
    seed(lp, SelectionScope.max_id_binds() + 50, 0.99)
    {_sql, big_params} = Repo.to_sql(:all, SelectionScope.to_query(scope))

    assert length(big_params) == length(small_params)
    refute sql =~ ~r/\bIN\s*\(/i
  end

  test "selection scope works for status: 'ignored'" do
    lp = library_path_fixture(%{type: "series"})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ignored1 =
      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "ig-1",
        relative_path: "ig-1/file.mkv",
        dismissed_at: now
      })

    ignored2 =
      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "ig-2",
        relative_path: "ig-2/file.mkv",
        dismissed_at: now
      })

    _pending =
      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "pend",
        relative_path: "pend/file.mkv"
      })

    # page mode
    page_scope =
      lp.id
      |> SelectionScope.new("ignored")
      |> SelectionScope.select_page([ignored1.anchor_key])

    assert SelectionScope.selected?(page_scope, ignored1.anchor_key)
    refute SelectionScope.selected?(page_scope, ignored2.anchor_key)
    assert SelectionScope.count(page_scope) == 1

    # filter mode (select all ignored)
    filter_scope =
      lp.id
      |> SelectionScope.new("ignored")
      |> SelectionScope.select_all_matching(%{})

    assert SelectionScope.count(filter_scope) == 2
    assert query_ids(filter_scope) == MapSet.new([ignored1.anchor_key, ignored2.anchor_key])
  end

  test "clear resets to none and preserves status" do
    lp = library_path_fixture(%{type: "series"})
    [a | _] = seed(lp, 2, 1.0)

    scope =
      lp.id
      |> SelectionScope.new("ignored")
      |> SelectionScope.select_page([a.anchor_key])
      |> SelectionScope.clear()

    assert scope.status == "ignored"
    assert SelectionScope.count(scope) == 0
    assert Repo.aggregate(SelectionScope.to_query(scope) |> Ecto.Query.subquery(), :count) == 0
  end

  describe "the id-bind cap is enforced once, at the write boundary" do
    test "select_page caps the included set so count/selected?/query all agree" do
      lp = library_path_fixture(%{type: "series"})
      cap = SelectionScope.max_id_binds()
      candidates = seed(lp, cap + 50, 1.0)
      keys = Enum.map(candidates, & &1.anchor_key)

      scope =
        lp.id
        |> SelectionScope.new()
        |> SelectionScope.select_page(keys)

      assert SelectionScope.count(scope) == cap

      assert Repo.aggregate(SelectionScope.to_query(scope) |> Ecto.Query.subquery(), :count) ==
               cap

      db_keys = query_ids(scope)
      assert MapSet.size(db_keys) == cap

      for key <- keys do
        assert SelectionScope.selected?(scope, key) == MapSet.member?(db_keys, key)
      end
    end

    test "toggle refuses to grow the page-mode selection past the cap" do
      lp = library_path_fixture(%{type: "series"})
      cap = SelectionScope.max_id_binds()
      candidates = seed(lp, cap + 50, 1.0)
      keys = Enum.map(candidates, & &1.anchor_key)

      scope =
        Enum.reduce(keys, SelectionScope.new(lp.id), fn key, acc ->
          SelectionScope.toggle(acc, key)
        end)

      assert SelectionScope.count(scope) == cap

      assert Repo.aggregate(SelectionScope.to_query(scope) |> Ecto.Query.subquery(), :count) ==
               cap

      db_keys = query_ids(scope)
      assert MapSet.size(db_keys) == cap

      for key <- keys do
        assert SelectionScope.selected?(scope, key) == MapSet.member?(db_keys, key)
      end
    end

    test "toggle refuses to grow filter-mode exclusions past the cap" do
      lp = library_path_fixture(%{type: "series"})
      cap = SelectionScope.max_id_binds()
      candidates = seed(lp, cap + 50, 1.0)
      keys = Enum.map(candidates, & &1.anchor_key)

      scope =
        lp.id
        |> SelectionScope.new()
        |> SelectionScope.select_all_matching(%{band: :ready})

      scope = Enum.reduce(keys, scope, fn key, acc -> SelectionScope.toggle(acc, key) end)

      db_keys = query_ids(scope)
      db_count = Repo.aggregate(SelectionScope.to_query(scope) |> Ecto.Query.subquery(), :count)

      assert SelectionScope.count(scope) == db_count
      assert MapSet.size(db_keys) == db_count
      # cap keys got excluded, so the remaining selected set is (cap + 50) - cap.
      assert db_count == 50

      for key <- keys do
        assert SelectionScope.selected?(scope, key) == MapSet.member?(db_keys, key)
      end
    end
  end
end
