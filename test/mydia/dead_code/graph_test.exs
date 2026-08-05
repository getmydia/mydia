defmodule Mydia.DeadCode.GraphTest do
  use ExUnit.Case, async: true

  alias Mydia.DeadCode.Graph

  defp never_exempt, do: fn _module -> false end
  defp only(module), do: fn candidate -> candidate == module end

  test "a module called from a live file is live" do
    # App.Entry stands in for a framework entry point: exempt, so it anchors
    # the graph. Without a root, nothing is reachable and nothing is live.
    definitions = %{App.Entry => "lib/app/entry.ex", Live.Callee => "lib/callee.ex"}
    edges = [{Live.Callee, "lib/app/entry.ex"}]

    result = Graph.classify(definitions, edges, only(App.Entry))

    assert Live.Callee in result.live
    assert App.Entry in result.live
  end

  test "a module referenced only from an unreachable file is not live" do
    # Structurally identical to the test above, minus the exempt root. This is
    # the pair that pins the semantics: an inbound edge alone does not confer
    # liveness, only an inbound edge from something reachable does.
    definitions = %{Dead.Caller => "lib/dead/caller.ex", Dead.Callee => "lib/dead/callee.ex"}
    edges = [{Dead.Callee, "lib/dead/caller.ex"}]

    result = Graph.classify(definitions, edges, never_exempt())

    assert Dead.Caller in result.orphan
    assert Dead.Callee in result.orphan
    assert result.live == []
  end

  test "a self-reference does not make a module live" do
    definitions = %{Solo.Mod => "lib/solo.ex"}
    edges = [{Solo.Mod, "lib/solo.ex"}]

    result = Graph.classify(definitions, edges, never_exempt())

    assert Solo.Mod in result.orphan
  end

  test "a module referenced only from test/ is test_only" do
    definitions = %{Tested.Mod => "lib/tested.ex"}
    edges = [{Tested.Mod, "test/tested_test.exs"}]

    result = Graph.classify(definitions, edges, never_exempt())

    assert Tested.Mod in result.test_only
    refute Tested.Mod in result.live
  end

  test "a module referenced from nowhere is an orphan" do
    definitions = %{Lonely.Mod => "lib/lonely.ex"}

    result = Graph.classify(definitions, [], never_exempt())

    assert Lonely.Mod in result.orphan
  end

  test "an exempt module is live even with no callers" do
    definitions = %{Mix.Tasks.Something => "lib/mix/tasks/something.ex"}
    exempt = fn module -> module == Mix.Tasks.Something end

    result = Graph.classify(definitions, [], exempt)

    assert Mix.Tasks.Something in result.live
  end

  # The mutual reference between Context and Schema is the point: this cluster
  # cites itself into looking alive under any "has an inbound edge" rule.
  # Models adult_scanner / Adult / Scene, which no analysis ever flagged.
  test "a self-referencing cluster unreachable from any root collapses entirely" do
    definitions = %{
      Island.Scanner => "lib/island/scanner.ex",
      Island.Context => "lib/island/context.ex",
      Island.Schema => "lib/island/schema.ex"
    }

    edges = [
      {Island.Context, "lib/island/scanner.ex"},
      {Island.Schema, "lib/island/context.ex"},
      {Island.Context, "lib/island/schema.ex"}
    ]

    result = Graph.classify(definitions, edges, never_exempt())

    assert Island.Scanner in result.orphan
    assert Island.Context in result.orphan
    assert Island.Schema in result.orphan
    assert result.live == []
  end

  test "a cluster reachable from an exempt root stays live" do
    definitions = %{
      App.Entry => "lib/app/entry.ex",
      Anchored.Entry => "lib/anchored/entry.ex",
      Anchored.Helper => "lib/anchored/helper.ex"
    }

    edges = [
      {Anchored.Entry, "lib/app/entry.ex"},
      {Anchored.Helper, "lib/anchored/entry.ex"}
    ]

    result = Graph.classify(definitions, edges, only(App.Entry))

    assert Anchored.Entry in result.live
    assert Anchored.Helper in result.live
  end

  # Termination guard: the closure must not loop forever on a cycle it can reach.
  test "a cycle reachable from an exempt root stays live and terminates" do
    definitions = %{
      App.Entry => "lib/app/entry.ex",
      Ring.A => "lib/ring/a.ex",
      Ring.B => "lib/ring/b.ex"
    }

    edges = [
      {Ring.A, "lib/app/entry.ex"},
      {Ring.B, "lib/ring/a.ex"},
      {Ring.A, "lib/ring/b.ex"}
    ]

    result = Graph.classify(definitions, edges, only(App.Entry))

    assert Ring.A in result.live
    assert Ring.B in result.live
    assert result.orphan == []
  end

  test "an edge from a template is attributed to the module that embeds it" do
    # show.html.heex defines no module, so without attribution its edge is
    # dropped and Show.Components reports as an orphan. This is the 20-finding
    # false-positive class from the Task 5 audit.
    definitions = %{
      App.Entry => "lib/app/entry.ex",
      Web.Show => "lib/web/show.ex",
      Web.Show.Components => "lib/web/show/components.ex"
    }

    edges = [
      {Web.Show, "lib/app/entry.ex"},
      {Web.Show.Components, "lib/web/show.html.heex"}
    ]

    result = Graph.classify(definitions, edges, only(App.Entry))

    assert Web.Show.Components in result.live
  end

  test "a template belonging to a dead module does not confer liveness" do
    # No root reaches Web.Dead, so its template must not resurrect the
    # components it calls.
    definitions = %{
      Web.Dead => "lib/web/dead.ex",
      Web.Dead.Components => "lib/web/dead/components.ex"
    }

    edges = [{Web.Dead.Components, "lib/web/dead.html.heex"}]

    result = Graph.classify(definitions, edges, never_exempt())

    assert Web.Dead.Components in result.orphan
    assert result.live == []
  end

  test "a template in a directory owned by a parent module confers liveness through that parent" do
    # Mirrors the MusicPlayerLive regression: root.html.heex lives under
    # layouts/, but embed_templates "layouts/*" means the owning module is
    # layouts.ex, one directory up from the template, not a colocated sibling.
    definitions = %{
      App.Entry => "lib/app/entry.ex",
      Web.Layouts => "lib/web/layouts.ex",
      Web.MusicPlayer => "lib/web/music_player.ex"
    }

    edges = [
      {Web.Layouts, "lib/app/entry.ex"},
      {Web.MusicPlayer, "lib/web/layouts/root.html.heex"}
    ]

    result = Graph.classify(definitions, edges, only(App.Entry))

    assert Web.MusicPlayer in result.live
  end

  test "a template owned by a dead parent-directory module does not confer liveness" do
    # Equivalent of the colocated dead-template guard above, but for the
    # directory-embed path: no root reaches Web.Layouts, so a template under
    # layouts/ must not resurrect the module it calls.
    definitions = %{
      Web.Layouts => "lib/web/layouts.ex",
      Web.MusicPlayer => "lib/web/music_player.ex"
    }

    edges = [{Web.MusicPlayer, "lib/web/layouts/root.html.heex"}]

    result = Graph.classify(definitions, edges, never_exempt())

    assert Web.MusicPlayer in result.orphan
    assert result.live == []
  end

  test "an edge from an unattributable file is left alone" do
    # No sibling .ex exists, so the edge keeps its original caller file and
    # simply never confers liveness. It must not crash or be misattributed.
    definitions = %{Lonely.Mod => "lib/lonely.ex"}
    edges = [{Lonely.Mod, "lib/orphaned_template.html.heex"}]

    result = Graph.classify(definitions, edges, never_exempt())

    assert Lonely.Mod in result.orphan
  end
end
