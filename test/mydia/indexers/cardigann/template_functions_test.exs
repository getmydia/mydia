defmodule Mydia.Indexers.Cardigann.TemplateFunctionsTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.TemplateFunctions

  describe "slice/3" do
    test "slices with integer and numeric string bounds" do
      assert TemplateFunctions.slice("abcdef", 1, 3) == "bc"
      assert TemplateFunctions.slice("abcdef", "2", "4") == "cd"
      assert TemplateFunctions.slice("abcdef", "2") == "cdef"
    end

    test "returns an empty string when a bound is not numeric" do
      assert TemplateFunctions.slice("abcdef", "x", 3) == ""
      assert TemplateFunctions.slice("abcdef", 1, "y") == ""
      assert TemplateFunctions.slice("abcdef", "") == ""
      assert TemplateFunctions.slice("abcdef", "1x") == ""
    end
  end
end
