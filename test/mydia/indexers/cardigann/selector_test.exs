defmodule Mydia.Indexers.Cardigann.SelectorTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Selector

  defp count(html, selector) do
    doc = Selector.parse(html, [selector])
    doc |> Selector.find(:root, selector) |> length()
  end

  describe "HTML5 tree construction" do
    test "a table without tbody matches a tbody selector" do
      html = "<table id=t><tr><td>a</td></tr><tr><td>b</td></tr></table>"
      assert count(html, "table#t > tbody > tr") == 2
    end
  end

  describe "standard CSS lexbor evaluates natively" do
    test "nested :has" do
      html =
        ~s(<table><tr><td><a href="magnet:?xt=1">m</a></td></tr><tr><td>none</td></tr></table>)

      assert count(html, ~S|tr:has(td:has(a[href^="magnet:?xt="]))|) == 1
    end

    test ":not(:has())" do
      html = ~s(<div class=c><p>x</p></div><div class=c><span class=e>y</span></div>)
      assert count(html, "div.c:not(:has(span.e))") == 1
    end

    test "nth-child inside :has" do
      html =
        ~s(<a class=r><div><span>1</span><span>2</span></div></a><a class=r><div><span>1</span></div></a>)

      assert count(html, "a.r:has(div span:nth-child(2))") == 1
    end

    test "general sibling combinator inside :has" do
      html = ~s(<div id=c><div class=p></div><div class=e><a class=d>x</a></div></div>)
      assert count(html, "div#c > div.p:has(~ div.e a.d)") == 1
    end
  end

  describe ":contains" do
    test "top level" do
      html = "<ul><li>alpha one</li><li>beta two</li></ul>"
      assert count(html, ~S|li:contains("beta")|) == 1
    end

    test "inside :not with an apostrophe in the needle" do
      html =
        "<table><tbody><tr><td>row</td></tr><tr><td>We couldn't find anything for x</td></tr></tbody></table>"

      assert count(
               html,
               ~S|table > tbody > tr:has(td):not(:contains("We couldn't find anything for"))|
             ) == 1
    end

    test "inside :not(:has()), as pctorrent uses it" do
      html =
        ~s(<div class=d><div class=r>Soon!</div></div><div class=d><div class=r>Ready</div></div>)

      assert count(html, ~S|div.d:has(div.r):not(:has(div.r:contains("Soon!")))|) == 1
    end

    test "single quotes and unquoted" do
      html = "<p>one</p><p>two</p>"
      assert count(html, "p:contains('two')") == 1
      assert count(html, "p:contains(two)") == 1
    end

    test "in a selector list" do
      html = "<p>one</p><p>two</p><i>three</i>"
      assert count(html, ~S|p:contains("one"), i|) == 2
    end

    test "an undeclared needle raises" do
      doc = Selector.parse("<p>x</p>", [])

      assert_raise ArgumentError, ~r/not declared/, fn ->
        Selector.find(doc, :root, ~S|p:contains("x")|)
      end
    end
  end

  describe "scoped find, text, attribute" do
    test "find inside a row" do
      html =
        ~s(<table><tr><td class=t> Copper Lantern </td><td><a href="/d/1">d</a></td></tr></table>)

      doc = Selector.parse(html, ["tr", "td.t", "a"])
      [row] = Selector.find(doc, :root, "tr")
      assert doc |> Selector.find(row, "td.t") |> Selector.text() == " Copper Lantern "
      assert doc |> Selector.find(row, "a") |> Selector.attribute("href") == "/d/1"
    end

    test "nil selector is the scope itself" do
      doc = Selector.parse("<p>x</p>", ["p"])
      [p] = Selector.find(doc, :root, "p")
      assert Selector.find(doc, p, nil) == [p]
    end

    test "invalid CSS raises naming the selector" do
      doc = Selector.parse("<p>x</p>", [])
      assert_raise ArgumentError, ~r/p\[\[/, fn -> Selector.find(doc, :root, "p[[") end
    end
  end

  describe ":contains needles with special characters" do
    test "parentheses in a quoted needle" do
      html = "<p>total (all)</p><p>total</p>"
      assert count(html, ~S|p:contains("total (all)")|) == 1
    end

    test "escaped quote, also inside :has and :not" do
      html = ~S|<div class=a><b>say "hi"</b></div><div class=a><b>other</b></div>|
      assert count(html, ~S|b:contains("say \"hi\"")|) == 1
      assert count(html, ~S|div.a:has(b:contains("say \"hi\""))|) == 1
      assert count(html, ~S|div.a:not(:has(b:contains("say \"hi\"")))|) == 1
    end
  end

  describe "text/1 and attribute/2 edges" do
    test "text concatenates multiple nodes" do
      doc = Selector.parse("<p>one</p><p>two</p>", ["p"])
      assert doc |> Selector.find(:root, "p") |> Selector.text() == "onetwo"
    end

    test "attribute on an empty list and on a missing attribute" do
      doc = Selector.parse("<p>x</p>", ["p"])
      assert Selector.attribute([], "href") == nil
      assert doc |> Selector.find(:root, "p") |> Selector.attribute("href") == nil
    end
  end

  describe ":scope" do
    test "resolves to the element searched from, not to every ancestor match" do
      html = ~s(<div id=a><span>one</span><div id=b><span>two</span></div></div>)
      doc = Selector.parse(html, ["div"])
      [outer] = Selector.find(doc, :root, "div#a")
      [inner] = Selector.find(doc, :root, "div#b")

      assert outer |> then(&Selector.find(doc, &1, ":scope > span")) |> Selector.text() == "one"
      assert inner |> then(&Selector.find(doc, &1, ":scope > span")) |> Selector.text() == "two"
    end

    test "leaves :scope inside a quoted attribute value alone" do
      html = ~s(<div><a href="x:scope">hit</a><a href="y">miss</a></div>)
      selector = ~S|a[href*=":scope"]|
      doc = Selector.parse(html, [selector])
      [row] = Selector.find(doc, :root, "div")

      assert doc |> Selector.find(row, selector) |> Selector.text() == "hit"
      assert doc |> Selector.find(row, ~S|:scope > a[href*=":scope"]|) |> length() == 1
    end

    test "does not rewrite a longer identifier that starts with scope" do
      html = ~s(<div><scopeless>x</scopeless></div>)
      doc = Selector.parse(html, ["scopeless"])
      assert doc |> Selector.find(:root, "scopeless") |> length() == 1
    end

    test "combines with :contains() and comma alternatives" do
      html = ~s(<div><span>a ago</span><span>b</span></div>)
      selector = ~S|:scope > span:contains("ago"), :scope > i|
      doc = Selector.parse(html, [selector])
      [row] = Selector.find(doc, :root, "div")

      assert doc |> Selector.find(row, selector) |> length() == 1
    end
  end

  describe "without/3" do
    test "keeps the node itself when it matches the remove selector" do
      html = ~s(<table><tr><td class=t>Paper Harbor<span class=t> [junk]</span></td></tr></table>)
      doc = Selector.parse(html, ["td.t", ".t"])
      [cell] = Selector.find(doc, :root, "td.t")
      stripped = Selector.without(doc, cell, [".t"])
      assert Selector.text([stripped]) == "Paper Harbor"
    end

    test "removes matching descendants before reading text" do
      html = ~s(<table><tr><td class=t>Paper Harbor<span class=x> [junk]</span></td></tr></table>)
      doc = Selector.parse(html, ["td.t", "span.x"])
      [cell] = Selector.find(doc, :root, "td.t")
      stripped = Selector.without(doc, cell, ["span.x"])
      assert Selector.text([stripped]) == "Paper Harbor"
    end
  end
end
