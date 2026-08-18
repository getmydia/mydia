defmodule Mydia.Library.SelectionScopeTest do
  use Mydia.DataCase, async: true

  import Mydia.SettingsFixtures

  alias Mydia.ImportGroups
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

  defp insert_group(attrs) do
    %ImportGroup{}
    |> ImportGroup.changeset(Map.merge(%{status: "pending"}, attrs))
    |> Repo.insert!()
  end

  defp query_ids(scope) do
    scope |> SelectionScope.to_query() |> Repo.all() |> Enum.map(& &1.id) |> MapSet.new()
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

  test "filter mode never puts ids in the query, independent of how many rows match" do
    lp = library_path_fixture(%{type: "series"})
    seed(lp, 3, 1.0)

    scope =
      lp.id
      |> SelectionScope.new()
      |> SelectionScope.select_all_matching(%{band: :ready})

    {sql, small_params} = Repo.to_sql(:all, SelectionScope.to_query(scope))

    assert is_binary(sql)
    # library_path_id and the band threshold are the only pinned (^) values in
    # the query; the "pending" status literal is unpinned, so Ecto compiles it
    # directly into the SQL text rather than binding it. Two params, none of
    # them per-row.
    assert length(small_params) == 2

    # Prove it's a shape property, not an artifact of the 3-row fixture: adding
    # hundreds more matching rows (well past `max_id_binds/0`) must not change
    # the parameter count at all, because `to_query/1`'s `:filter` clause never
    # inspects matching rows to build the query in the first place. A distinct
    # confidence (still >= the :ready threshold) keeps cluster_key unique
    # against the first `seed/3` call above.
    seed(lp, SelectionScope.max_id_binds() + 50, 0.99)
    {_sql, big_params} = Repo.to_sql(:all, SelectionScope.to_query(scope))

    assert length(big_params) == length(small_params)
    refute sql =~ ~r/\bIN\s*\(/i
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

  describe "the id-bind cap is enforced once, at the write boundary" do
    test "select_page caps the included set so count/selected?/query all agree" do
      lp = library_path_fixture(%{type: "series"})
      cap = SelectionScope.max_id_binds()
      groups = seed(lp, cap + 50, 1.0)
      ids = Enum.map(groups, & &1.id)

      scope =
        lp.id
        |> SelectionScope.new()
        |> SelectionScope.select_page(ids)

      assert SelectionScope.count(scope) == cap
      assert Repo.aggregate(SelectionScope.to_query(scope), :count) == cap

      db_ids = query_ids(scope)
      assert MapSet.size(db_ids) == cap

      for id <- ids do
        assert SelectionScope.selected?(scope, id) == MapSet.member?(db_ids, id)
      end
    end

    test "toggle refuses to grow the page-mode selection past the cap" do
      lp = library_path_fixture(%{type: "series"})
      cap = SelectionScope.max_id_binds()
      groups = seed(lp, cap + 50, 1.0)
      ids = Enum.map(groups, & &1.id)

      scope =
        Enum.reduce(ids, SelectionScope.new(lp.id), fn id, acc ->
          SelectionScope.toggle(acc, id)
        end)

      assert SelectionScope.count(scope) == cap
      assert Repo.aggregate(SelectionScope.to_query(scope), :count) == cap

      db_ids = query_ids(scope)
      assert MapSet.size(db_ids) == cap

      for id <- ids do
        assert SelectionScope.selected?(scope, id) == MapSet.member?(db_ids, id)
      end
    end

    test "toggle refuses to grow filter-mode exclusions past the cap" do
      lp = library_path_fixture(%{type: "series"})
      cap = SelectionScope.max_id_binds()
      groups = seed(lp, cap + 50, 1.0)
      ids = Enum.map(groups, & &1.id)

      scope =
        lp.id
        |> SelectionScope.new()
        |> SelectionScope.select_all_matching(%{band: :ready})

      scope = Enum.reduce(ids, scope, fn id, acc -> SelectionScope.toggle(acc, id) end)

      db_ids = query_ids(scope)
      db_count = Repo.aggregate(SelectionScope.to_query(scope), :count)

      assert SelectionScope.count(scope) == db_count
      assert MapSet.size(db_ids) == db_count
      # cap ids got excluded, so the remaining selected set is (cap + 50) - cap.
      assert db_count == 50

      for id <- ids do
        assert SelectionScope.selected?(scope, id) == MapSet.member?(db_ids, id)
      end
    end
  end

  describe "band and search predicates agree with ImportGroups.page/2" do
    test "every band returns the same ids from both modules" do
      lp = library_path_fixture(%{type: "series"})
      seed(lp, 3, 1.0)
      seed(lp, 2, 0.5)

      insert_group(%{
        library_path_id: lp.id,
        anchor_path: "NoMatch",
        cluster_key: "no-match",
        file_count: 1
      })

      # A group whose members disagreed on provider: non-nil provider_id, but
      # no min_confidence. Task 6 writes this shape; it must fall out of BOTH
      # :ready and :needs_attention in both modules, identically.
      insert_group(%{
        library_path_id: lp.id,
        anchor_path: "Disagreement",
        cluster_key: "disagreement",
        file_count: 1,
        provider_id: "9",
        min_confidence: nil
      })

      # A locally-created group (ImportGroups.create_local_show/1) whose
      # leftover member later picked up a high-confidence MatchCandidate of
      # its own: non-nil (synthetic) provider_id, min_confidence above
      # threshold -- exactly the shape that must never be :ready in either
      # module, since its provider_id is a marker, not a real match.
      insert_group(%{
        library_path_id: lp.id,
        anchor_path: "LocalShow",
        cluster_key: "local-show",
        file_count: 1,
        provider_type: "local",
        provider_id: "local-deadbeef",
        min_confidence: 1.0
      })

      for band <- [:ready, :needs_attention, :no_match] do
        {page_groups, _cursor} = ImportGroups.page(lp.id, band: band, limit: 1000)
        page_ids = page_groups |> Enum.map(& &1.id) |> MapSet.new()

        scope =
          lp.id
          |> SelectionScope.new()
          |> SelectionScope.select_all_matching(%{band: band})

        assert query_ids(scope) == page_ids,
               "band #{inspect(band)} diverged between the two modules"
      end
    end

    test "a search term returns the same ids from both modules" do
      lp = library_path_fixture(%{type: "series"})
      seed(lp, 3, 1.0)

      insert_group(%{
        library_path_id: lp.id,
        anchor_path: "100%_Weird Name",
        cluster_key: "weird",
        file_count: 1,
        provider_id: "1",
        min_confidence: 1.0
      })

      for q <- ["s1", "100%_weird"] do
        {page_groups, _cursor} = ImportGroups.page(lp.id, q: q, limit: 1000)
        page_ids = page_groups |> Enum.map(& &1.id) |> MapSet.new()

        scope =
          lp.id
          |> SelectionScope.new()
          |> SelectionScope.select_all_matching(%{q: q})

        assert query_ids(scope) == page_ids,
               "search #{inspect(q)} diverged between the two modules"
      end
    end
  end
end
