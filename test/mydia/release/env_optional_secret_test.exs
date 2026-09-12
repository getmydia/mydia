defmodule Mydia.Release.EnvOptionalSecretTest do
  use ExUnit.Case, async: false

  alias Mydia.Release.Env

  @var "MYDIA_TEST_OPTIONAL_SECRET"

  setup do
    on_exit(fn -> System.delete_env(@var) end)
    :ok
  end

  test "returns nil when the variable is unset" do
    System.delete_env(@var)
    assert Env.fetch_optional_secret(@var) == nil
  end

  test "returns nil when the variable is empty" do
    System.put_env(@var, "")
    assert Env.fetch_optional_secret(@var) == nil
  end

  test "returns nil when the variable is whitespace only" do
    System.put_env(@var, "   \n\t ")
    assert Env.fetch_optional_secret(@var) == nil
  end

  test "raises when the value is shorter than the minimum length" do
    System.put_env(@var, "too-short")

    assert_raise RuntimeError, ~r/is too short/, fn ->
      Env.fetch_optional_secret(@var)
    end
  end

  test "returns the value when it is long enough" do
    value = String.duplicate("a", 32)
    System.put_env(@var, value)
    assert Env.fetch_optional_secret(@var) == value
  end

  test "honours a custom minimum length" do
    System.put_env(@var, String.duplicate("a", 8))

    assert Env.fetch_optional_secret(@var, min_length: 8) == String.duplicate("a", 8)
    assert_raise RuntimeError, fn -> Env.fetch_optional_secret(@var, min_length: 9) end
  end
end
