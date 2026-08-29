defmodule Mydia.Settings.ConfigSettingTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings.ConfigSetting

  defp changeset(attrs) do
    ConfigSetting.changeset(%ConfigSetting{}, attrs)
  end

  describe "changeset/2 key validation" do
    test "accepts a key naming a schema field" do
      assert changeset(%{"key" => "server.port", "value" => "8080", "category" => :server}).valid?
    end

    test "accepts a direct-lookup key with no schema field" do
      assert changeset(%{
               "key" => "crash_reporting.enabled",
               "value" => "true",
               "category" => :crash_reporting
             }).valid?
    end

    test "rejects a key the schema does not have" do
      cs = changeset(%{"key" => "server.nonexistent", "value" => "1", "category" => :server})

      refute cs.valid?
      assert %{key: [_ | _]} = errors_on(cs)
    end

    test "rejects a key that would collide with a section" do
      # Two rows named `server` and `server.port` used to raise BadMapError
      # during the merge and stop the application from starting.
      cs = changeset(%{"key" => "server", "value" => "4000", "category" => :server})

      refute cs.valid?
      assert %{key: [_ | _]} = errors_on(cs)
    end
  end

  describe "changeset/2 value validation" do
    test "rejects a value that will not cast to the field's type" do
      cs = changeset(%{"key" => "server.port", "value" => "abc", "category" => :server})

      refute cs.valid?
      assert %{value: [_ | _]} = errors_on(cs)
    end

    test "accepts an empty value, which means unset" do
      # media.default_quality_profile_id is persisted with an empty value to
      # record a cleared default, so empty must stay legal.
      assert changeset(%{
               "key" => "media.default_quality_profile_id",
               "value" => "",
               "category" => :media
             }).valid?

      assert changeset(%{"key" => "server.url_host", "value" => "", "category" => :server}).valid?
    end

    test "does not add a value error when the key is already invalid" do
      cs = changeset(%{"key" => "nope.nope", "value" => "abc", "category" => :server})

      refute cs.valid?
      assert %{key: [_ | _]} = errors_on(cs)
      refute Map.has_key?(errors_on(cs), :value)
    end
  end
end
