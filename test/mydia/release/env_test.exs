defmodule Mydia.Release.EnvTest do
  # Mutates process-global environment variables via System.put_env/2, so
  # this must stay async: false (see project memory on global-env test
  # leaks under concurrency).
  use ExUnit.Case, async: false

  alias Mydia.Release.Env

  @env_var "MYDIA_RELEASE_ENV_TEST_VAR"

  setup do
    System.delete_env(@env_var)
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  describe "fetch!/2" do
    test "returns the value when set" do
      System.put_env(@env_var, "hello")
      assert Env.fetch!(@env_var) == "hello"
    end

    test "raises when the variable is unset" do
      assert_raise RuntimeError, ~r/#{@env_var} is missing/, fn ->
        Env.fetch!(@env_var)
      end
    end

    test "raises on an empty string -- the `||` idiom's blind spot" do
      System.put_env(@env_var, "")

      assert_raise RuntimeError, ~r/#{@env_var} is missing/, fn ->
        Env.fetch!(@env_var)
      end
    end

    test "raises on a whitespace-only value" do
      System.put_env(@env_var, "   \n\t  ")

      assert_raise RuntimeError, ~r/#{@env_var} is missing/, fn ->
        Env.fetch!(@env_var)
      end
    end

    test "appends the hint to the error message when given" do
      assert_raise RuntimeError, ~r/generate one with: mix do_thing/, fn ->
        Env.fetch!(@env_var, "generate one with: mix do_thing")
      end
    end
  end

  describe "fetch_secret!/2" do
    test "returns the value when it meets the default minimum length" do
      value = String.duplicate("a", 32)
      System.put_env(@env_var, value)
      assert Env.fetch_secret!(@env_var) == value
    end

    test "returns a 64-character value produced by mix phx.gen.secret's default length" do
      value = String.duplicate("a", 64)
      System.put_env(@env_var, value)
      assert Env.fetch_secret!(@env_var) == value
    end

    test "raises on an empty string -- this is the confirmed T-101/T-103 auth-bypass case" do
      System.put_env(@env_var, "")

      assert_raise RuntimeError, ~r/#{@env_var} is missing/, fn ->
        Env.fetch_secret!(@env_var)
      end
    end

    test "raises on a whitespace-only value" do
      System.put_env(@env_var, "   ")

      assert_raise RuntimeError, ~r/#{@env_var} is missing/, fn ->
        Env.fetch_secret!(@env_var)
      end
    end

    test "raises when shorter than the minimum length, naming the variable and length" do
      System.put_env(@env_var, "too-short")

      assert_raise RuntimeError, ~r/#{@env_var} is too short \(9 characters/, fn ->
        Env.fetch_secret!(@env_var)
      end
    end

    test "honors a custom :min_length" do
      System.put_env(@env_var, "1234567890")

      assert Env.fetch_secret!(@env_var, min_length: 10) == "1234567890"

      assert_raise RuntimeError, ~r/too short/, fn ->
        Env.fetch_secret!(@env_var, min_length: 11)
      end
    end

    test "includes the hint in a too-short error" do
      System.put_env(@env_var, "short")

      assert_raise RuntimeError, ~r/mix guardian.gen.secret/, fn ->
        Env.fetch_secret!(@env_var, hint: "mix guardian.gen.secret")
      end
    end
  end
end
