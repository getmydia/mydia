defmodule Mydia.Indexers.Cardigann.BlockPageTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.BlockPage
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @blocked File.read!("test/fixtures/cardigann/block_page/response.html")

  defp definition(row_selector), do: %Parsed{id: "b", search: %{rows: %{selector: row_selector}}}

  test "an ISP block page is fingerprinted" do
    assert BlockPage.fingerprint(@blocked) =~ "Blocked"
  end

  test "a domain-for-sale page is fingerprinted" do
    assert BlockPage.fingerprint(
             "<html><head><title>example.invalid - This website is for sale!</title></head></html>"
           )
  end

  test "a tracker title that merely contains the words for sale is not" do
    refute BlockPage.fingerprint(
             "<html><head><title>Copper Lantern guitars for sale - Latest Torrents</title></head></html>"
           )
  end

  test "an ordinary results page is not" do
    refute BlockPage.fingerprint("<html><head><title>Latest Torrents</title></head></html>")
  end

  test "a fingerprinted page with matching rows is not blocked" do
    body =
      "<html><head><title>Website is blocked list</title></head><body><table><tr class=r><td>x</td></tr></table></body></html>"

    refute BlockPage.blocked?(definition("tr.r"), %{status: 200, body: body})
  end

  test "a fingerprinted page with no rows is blocked" do
    assert BlockPage.blocked?(definition("tr.r"), %{status: 200, body: @blocked})
  end

  test "JSON bodies are never block pages" do
    refute BlockPage.blocked?(definition("tr.r"), %{status: 200, body: %{"data" => []}})
  end

  test "non-200 responses are never block pages" do
    refute BlockPage.blocked?(definition("tr.r"), %{status: 403, body: @blocked})
  end
end
