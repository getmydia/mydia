defmodule Mydia.Health.Alerts.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Mydia.Health.Alert
  alias Mydia.Health.Alerts.Evaluator

  @t0 ~U[2026-01-01 00:00:00Z]
  @obs %{title: "VPN down", detail: "d", fix_path: "/admin/clients"}

  defp at(min), do: DateTime.add(@t0, min * 60, :second)

  # Runs a sequence of {minute, observations} through the evaluator and
  # returns the alerts from the last step plus the final state.
  defp run(steps, state \\ %{}) do
    Enum.reduce(steps, {[], state}, fn {min, obs}, {_alerts, state} ->
      Evaluator.evaluate(obs, state, at(min))
    end)
  end

  defp failing(mins, obs \\ @obs), do: Enum.map(mins, &{&1, %{vpn: obs}})
  defp clear(mins), do: Enum.map(mins, &{&1, %{vpn: nil}})

  test "thresholds" do
    assert Evaluator.raise_after_seconds() == 600
    assert Evaluator.clear_after_seconds() == 300
  end

  test "does not raise before 10 minutes" do
    assert {[], _} = run(failing([0]))
    assert {[], _} = run(failing([0, 9]))
  end

  test "raises at 10 minutes with since = first failure" do
    assert {[%Alert{key: :vpn, since: @t0, title: "VPN down", detail: "d"}], _} =
             run(failing([0, 10]))
  end

  test "a clear shorter than 5 minutes keeps the outage" do
    {_, state} = run(failing([0, 10]))
    assert {[%Alert{since: @t0}], state} = run(clear([12]), state)
    assert {[%Alert{since: @t0}], _} = run(failing([14]), state)
  end

  test "flapping before the threshold still accumulates" do
    steps = failing([0]) ++ clear([3]) ++ failing([6]) ++ clear([8]) ++ failing([10])
    assert {[%Alert{key: :vpn, since: @t0}], _} = run(steps)
  end

  test "clears after 5 minutes clear" do
    assert {[], state} = run(failing([0, 10]) ++ clear([11, 16]))
    refute Map.has_key?(state, :vpn)
  end

  test "a fresh failure after a full clear restarts the clock" do
    {[], state} = run(failing([0, 10]) ++ clear([11, 16]))
    assert {[], state} = run(failing([17]), state)
    expected_since = at(17)
    assert {[%Alert{since: ^expected_since}], _} = run(failing([27]), state)
  end

  test "keys are independent and sorted by since" do
    steps = [{0, %{a: @obs}}, {2, %{a: @obs, b: @obs}}, {12, %{a: @obs, b: @obs}}]
    assert {[%Alert{key: :a}, %Alert{key: :b}], _} = run(steps)
  end

  test "uses the latest observation text" do
    steps = [{0, %{vpn: %{@obs | title: "A"}}}, {10, %{vpn: %{@obs | title: "B"}}}]
    assert {[%Alert{title: "B"}], _} = run(steps)
  end

  test "an outage that recovered before 10 minutes never raises" do
    assert {[], _} = run(failing([0, 3, 7]) ++ clear([8, 9, 10, 11]))
  end

  test "a key absent from observations counts as clear" do
    assert {[], state} = run(failing([0, 10]) ++ [{11, %{}}, {16, %{}}])
    refute Map.has_key?(state, :vpn)
  end
end
