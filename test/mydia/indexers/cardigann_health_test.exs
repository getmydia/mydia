defmodule Mydia.Indexers.CardigannHealthTest do
  # Drives Mix.Tasks.Mydia.CardigannHealth.run/1 through Repo and a Bypass
  # server, so async: false to stay on the shared sandbox connection (see
  # cardigann_health_check_test.exs, which does the same for the same reason).
  use Mydia.DataCase, async: false

  import ExUnit.CaptureIO
  import Mydia.IndexersFixtures

  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannSearchEngine

  describe "CardigannSearchEngine.execute_search/3 options contract" do
    test "a map of options never matches, whatever the definition's fields are" do
      # execute_search/4's only clause is guarded `when is_list(opts)`. The
      # guard is checked before the body runs, so this raises purely because
      # opts is a map -- not because some nil field on an empty %Parsed{} got
      # dereferenced later. Confirmed by running this directly: the raised
      # FunctionClauseError points at the clause head itself
      # (cardigann_search_engine.ex:124), with the %Parsed{}'s all-nil fields
      # printed verbatim in the "no matching clause" argument dump, never
      # touched by any code that would raise a different error first.
      assert_raise FunctionClauseError, fn ->
        CardigannSearchEngine.execute_search(
          %Parsed{},
          %{query: "q", categories: [], search_path: nil},
          %{}
        )
      end
    end
  end

  describe "mix mydia.cardigann_health" do
    test "reports success for an enabled indexer instead of failing every search" do
      # Before the fix, do_test_indexer/2 built search_opts as a map.
      # execute_search/3 never matches a map, so every indexer's search
      # raised FunctionClauseError. test_indexer/3 rescues that into
      # %{status: :error, ...}, so the task itself doesn't crash -- but no
      # indexer could ever report "ok", regardless of how reachable it was.
      # This drives the real mix task end to end against a Bypass server to
      # prove that.
      definition = cardigann_definition_fixture(%{enabled: true})

      bypass = Bypass.open()
      Bypass.stub(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "<html/>") end)

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          ~s"""
          <html><body><table class="results">
          <tr><td class="title">Some Release</td>
          <td class="download"><a href="/download/1">grab</a></td></tr>
          </table></body></html>
          """
        )
      end)

      put_link(definition, "http://localhost:#{bypass.port}")

      output =
        capture_io(fn ->
          Mix.Tasks.Mydia.CardigannHealth.run(["--indexer", definition.indexer_id, "--json"])
        end)

      # --json still shares the "Testing N indexer(s)..." preamble that
      # print_results/1 prints, so the JSON document is everything from the
      # first "{" on.
      json_text = output |> String.split("{", parts: 2) |> Enum.at(1) |> then(&("{" <> &1))
      assert {:ok, json} = Jason.decode(json_text)
      assert [result] = json["results"]

      assert result["status"] == "ok"
      assert result["result_count"] == 1
      assert result["error"] == nil
    end
  end

  # Same rewrite cardigann_health_check_test.exs uses: the stored YAML, not
  # the definition's `links` column, is what CardigannParser reads, so
  # pointing the fixture at Bypass means rewriting the `links:` block inside
  # definition.definition.
  defp put_link(definition, url) do
    updated_yaml =
      String.replace(
        definition.definition,
        ~r/^links:\n(?:  - .*\n?)+/m,
        "links:\n  - #{url}\n"
      )

    {:ok, updated} =
      definition
      |> Ecto.Changeset.change(%{definition: updated_yaml})
      |> Mydia.Repo.update()

    updated
  end
end
