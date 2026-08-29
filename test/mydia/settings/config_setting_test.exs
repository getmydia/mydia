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

    test "does not add a value error when :key is absent from attrs" do
      cs = changeset(%{"value" => "8080", "category" => :server})

      refute cs.valid?
      assert %{key: [_ | _]} = errors_on(cs)
      refute Map.has_key?(errors_on(cs), :value)
    end

    test "blames the key, not the value, on a value-only update against a row whose existing key is already invalid" do
      # validate_change/3 (inside validate_known_key/1) is skipped by Ecto
      # whenever :key is absent from this changeset's changes, which is the
      # case on a value-only update -- e.g. the API's PATCH endpoint, which
      # only ever sends :value and :description. A row written before this
      # validation existed may carry an unknown key; updating just :value
      # must still blame :key, not surface as a :value error.
      existing = %ConfigSetting{key: "server.nonexistent", value: "1", category: :server}

      cs = ConfigSetting.changeset(existing, %{"value" => "2"})

      refute cs.valid?
      assert %{key: [_ | _]} = errors_on(cs)
      refute Map.has_key?(errors_on(cs), :value)
    end
  end
end
