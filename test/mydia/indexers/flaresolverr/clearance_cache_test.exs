defmodule Mydia.Indexers.FlareSolverr.ClearanceCacheTest do
  # Hosts below are unique per test, so the shared ETS table needs no reset.
  use ExUnit.Case, async: true

  alias Mydia.Indexers.FlareSolverr.{Clearance, ClearanceCache}

  defp cookie(name, value, domain, expires \\ -1) do
    %{
      name: name,
      value: value,
      domain: domain,
      path: "/",
      expires: expires,
      http_only: true,
      secure: true,
      same_site: nil
    }
  end

  defp host, do: "site#{System.unique_integer([:positive])}.example"

  test "stores cookies for the solved host with the user-agent they were issued to" do
    h = host()

    :ok =
      ClearanceCache.put(
        "https://#{h}/search?q=x",
        [cookie("cf_clearance", "abc", ".#{h}")],
        "UA/1",
        1_000
      )

    assert {:ok, %Clearance{cookies: [{"cf_clearance", "abc"}], user_agent: "UA/1"}} =
             ClearanceCache.lookup("https://#{h}/other", 1_001)
  end

  test "a cookie for another domain is not kept" do
    h = host()

    :ok =
      ClearanceCache.put(
        "https://#{h}/",
        [cookie("a", "1", h), cookie("b", "2", "tracker.example")],
        "UA",
        0
      )

    assert {:ok, %Clearance{cookies: [{"a", "1"}]}} = ClearanceCache.lookup("https://#{h}/", 1)
  end

  test "a different host or port gets nothing" do
    h = host()
    :ok = ClearanceCache.put("https://#{h}/", [cookie("a", "1", h)], "UA", 0)
    assert :none = ClearanceCache.lookup("https://mirror-#{h}/", 1)
    assert :none = ClearanceCache.lookup("https://#{h}:8443/", 1)
  end

  test "expires at the earliest future cookie expiry" do
    h = host()

    :ok =
      ClearanceCache.put(
        "https://#{h}/",
        [cookie("a", "1", h, 1_100.5), cookie("b", "2", h, 5_000)],
        "UA",
        1_000
      )

    assert {:ok, _} = ClearanceCache.lookup("https://#{h}/", 1_099)
    assert :none = ClearanceCache.lookup("https://#{h}/", 1_101)
  end

  test "without cookie expiries it lasts 30 minutes" do
    h = host()
    :ok = ClearanceCache.put("https://#{h}/", [cookie("a", "1", h)], "UA", 1_000)
    assert {:ok, _} = ClearanceCache.lookup("https://#{h}/", 1_000 + 1_799)
    assert :none = ClearanceCache.lookup("https://#{h}/", 1_000 + 1_801)
  end

  test "nothing usable is ignored" do
    assert :ignored = ClearanceCache.put("https://#{host()}/", [], nil, 0)
  end
end
