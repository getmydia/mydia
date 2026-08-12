defmodule Mydia.Subtitles.HealthTest do
  use ExUnit.Case, async: false

  alias Mydia.Subtitles.Health

  setup do
    Health.reset(:test_provider)
    on_exit(fn -> Health.reset(:test_provider) end)
    :ok
  end

  test "a fresh provider is available" do
    assert Health.available?(:test_provider)
  end

  test "stays available below the failure threshold" do
    Health.record_failure(:test_provider)
    Health.record_failure(:test_provider)

    assert Health.available?(:test_provider)
  end

  test "opens the circuit at three consecutive failures" do
    for _ <- 1..3, do: Health.record_failure(:test_provider)

    refute Health.available?(:test_provider)
  end

  test "a success resets the failure count" do
    Health.record_failure(:test_provider)
    Health.record_failure(:test_provider)
    Health.record_success(:test_provider)
    Health.record_failure(:test_provider)

    assert Health.available?(:test_provider)
  end

  test "admits a probe once the cooldown has passed" do
    for _ <- 1..3, do: Health.record_failure(:test_provider)
    refute Health.available?(:test_provider)

    Health.expire_cooldown_for_test(:test_provider)

    assert Health.available?(:test_provider)
  end

  test "an untracked provider is available" do
    assert Health.available?(:never_seen_before)
  end
end
