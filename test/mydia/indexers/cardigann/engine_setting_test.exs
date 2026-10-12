defmodule Mydia.Indexers.Cardigann.EngineSettingTest do
  # Reloads the cached runtime config.
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Cardigann.EngineSetting
  alias Mydia.Settings.ConfigSetting

  setup do
    previous = Application.get_env(:mydia, :runtime_config)
    Repo.delete_all(ConfigSetting)
    on_exit(fn -> Application.put_env(:mydia, :runtime_config, previous) end)
    :ok
  end

  @unset &__MODULE__.unset/1
  def unset(_name), do: nil

  test "defaults to builtin" do
    {:ok, _} = Mydia.Config.Loader.reload()
    assert EngineSetting.setting() == :builtin
  end

  test "save/2 writes the db overlay and reloads" do
    assert :ok = EngineSetting.save(:prowlarr, getenv: @unset)
    assert EngineSetting.setting() == :prowlarr
    assert Repo.get_by!(ConfigSetting, key: "cardigann.engine").value == "prowlarr"

    assert :ok = EngineSetting.save(:builtin, getenv: @unset)
    assert EngineSetting.setting() == :builtin
  end

  test "save/2 rolls the row back when the reload fails" do
    reload = fn -> {:error, :invalid_config} end

    assert {:error, :invalid_config} =
             EngineSetting.save(:prowlarr, getenv: @unset, reload: reload)

    assert Repo.get_by(ConfigSetting, key: "cardigann.engine") == nil
  end

  test "save/2 is refused while CARDIGANN_ENGINE is set" do
    getenv = fn "CARDIGANN_ENGINE" -> "builtin" end
    assert {:error, :env_locked} = EngineSetting.save(:prowlarr, getenv: getenv)
  end

  test "env_locked?/1 treats empty as unset" do
    assert EngineSetting.env_locked?(fn "CARDIGANN_ENGINE" -> "prowlarr" end)
    refute EngineSetting.env_locked?(fn "CARDIGANN_ENGINE" -> "" end)
    refute EngineSetting.env_locked?(fn "CARDIGANN_ENGINE" -> nil end)
  end
end
