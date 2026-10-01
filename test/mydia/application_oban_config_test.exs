defmodule Mydia.ApplicationObanConfigTest do
  use ExUnit.Case, async: false

  alias Mydia.Application, as: App
  alias Mydia.Config.Schema

  setup do
    original_config = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_config do
        Application.put_env(:mydia, :runtime_config, original_config)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    :ok
  end

  test "children/1 overlays oban runtime config when Oban is enabled" do
    fake_config = %Schema{
      oban: %Schema.Oban{poll_interval: 3333, max_age_days: 12}
    }

    Application.put_env(:mydia, :runtime_config, fake_config)

    base_oban = [
      repo: Mydia.Repo,
      queues: [default: 5],
      plugins: [{Oban.Plugins.Pruner, max_age: 86_400}]
    ]

    children = App.children(base_oban)

    assert {Oban, oban_opts} =
             Enum.find(children, fn
               {Oban, _} -> true
               _ -> false
             end)

    assert oban_opts[:stage_interval] == 3333
    {Oban.Plugins.Pruner, pruner_opts} = List.keyfind(oban_opts[:plugins], Oban.Plugins.Pruner, 0)
    assert pruner_opts[:max_age] == 12 * 86_400
  end

  test "children/1 starts the job status tracker before Oban" do
    children = App.children(repo: Mydia.Repo, queues: [default: 5], plugins: [])

    tracker_index = Enum.find_index(children, &(&1 == Mydia.Jobs.StatusTracker))
    oban_index = Enum.find_index(children, &match?({Oban, _}, &1))

    assert is_integer(tracker_index)
    assert is_integer(oban_index)
    # Oban can start a job the moment it is up, and a start event cast to a
    # tracker that does not exist yet is silently dropped.
    assert tracker_index < oban_index
  end
end
