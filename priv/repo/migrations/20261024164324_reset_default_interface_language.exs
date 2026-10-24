defmodule Mydia.Repo.Migrations.ResetDefaultInterfaceLanguage do
  use Ecto.Migration
  import Ecto.Query

  @moduledoc """
  Removes a stored `"interface_language" => "en"` from every user's preferences.

  Until interface translations shipped, the preference row was seeded with the
  full defaults map, whose `interface_language` was `"en"`, and nothing in the UI
  or API could change it. Every stored `"en"` is therefore a leftover default,
  not a choice. Left in place it would pin each existing user to English, since
  `Mydia.Locale` treats a stored code as an explicit pick. Removing the key lets
  them fall back to automatic (browser language, then the instance default).

  `preferences` is an Ecto `:map` column: JSON text on SQLite and jsonb on
  PostgreSQL. Rows are read schemaless, decoded when they arrive as a string,
  and written back through `type(^map, :map)` so each adapter's own dumper
  encodes the value the way it stores it.
  """

  def up, do: reset()

  # The removed value equals the old default, so there is nothing to restore.
  def down, do: :ok

  @doc false
  def reset do
    from(p in "user_preferences", select: {p.id, p.preferences})
    |> query_repo().all()
    |> Enum.each(fn {id, raw} ->
      prefs = decode(raw)

      if Map.get(prefs, "interface_language") == "en" do
        updated = Map.delete(prefs, "interface_language")

        from(p in "user_preferences",
          where: p.id == ^id,
          update: [set: [preferences: type(^updated, :map)]]
        )
        |> query_repo().update_all([])
      end
    end)

    :ok
  end

  defp decode(raw) when is_map(raw), do: raw

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode(_), do: %{}

  # `repo/0` from Ecto.Migration only works inside a migration runner. Tests
  # call `reset/0` directly, so fall back to Mydia.Repo outside that context.
  defp query_repo do
    case Process.get(:ecto_migration) do
      %{runner: _} -> repo()
      _ -> Mydia.Repo
    end
  end
end
