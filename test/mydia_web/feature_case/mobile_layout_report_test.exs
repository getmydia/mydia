defmodule MydiaWeb.FeatureCase.MobileLayoutReportTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.FeatureCase.MobileLayout.{Report, Violation}

  defp v(attrs) do
    struct!(
      %Violation{
        route: "/downloads",
        width: 320,
        state: nil,
        check: :escapes_viewport,
        selector: "#batch-actions div.join",
        detail: "right=372 vw=320"
      },
      attrs
    )
  end

  test "a violation matching a known entry is accepted" do
    known = [{"/downloads", 320, :escapes_viewport, "#batch-actions div.join", "why"}]
    assert Report.diff([v(%{})], known) == {[], []}
  end

  test "a violation with no entry is unexpected" do
    assert {[%Violation{}], []} = Report.diff([v(%{})], [])
  end

  test "an entry matching nothing is stale" do
    entry = {"/calendar", 320, :page_overflow, "html", "why"}
    assert Report.diff([], [entry]) == {[], [entry]}
  end

  test "states are part of the route key" do
    known = [{"/downloads#issues", 320, :escapes_viewport, "#batch-actions div.join", "why"}]
    assert {[_], [_]} = Report.diff([v(%{})], known)
    assert {[], []} = Report.diff([v(%{state: "issues"})], known)
  end

  test "one known entry accepts every duplicate violation with the same key" do
    known = [{"/downloads", 320, :escapes_viewport, "#batch-actions div.join", "why"}]
    assert Report.diff([v(%{}), v(%{detail: "right=400 vw=320"})], known) == {[], []}
  end

  test "format prints each violation and the entry that would accept it" do
    text = Report.format([v(%{})], [{"/calendar", 320, :page_overflow, "html", "old"}])

    assert text =~ "/downloads @320 escapes_viewport #batch-actions div.join right=372 vw=320"

    assert text =~
             ~s|accept with: {"/downloads", 320, :escapes_viewport, "#batch-actions div.join", "<reason>"}|

    assert text =~ "fixed, remove from @known"
    assert text =~ ~s|{"/calendar", 320, :page_overflow, "html", "old"}|
  end
end
