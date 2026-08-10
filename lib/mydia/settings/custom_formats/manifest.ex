defmodule Mydia.Settings.CustomFormats.Manifest do
  @moduledoc """
  Compile-time loader for the built-in custom format definitions in
  `priv/custom_formats/*.exs`.

  Files are read with `Code.eval_file/1` at compile time and registered as
  `@external_resource`, so `mix compile` re-runs this module whenever a
  manifest file changes. This mirrors `Mydia.Library.ReleaseParser.Vocabulary`.

  Built-ins are always present and need no seeding. A DB row in
  `custom_formats` sharing a slug overrides the entry here; see
  `Mydia.Settings.CustomFormats.list_all/0` for the merge. Shipping the
  definitions in code is what lets a later release improve a regex for every
  operator who has not explicitly edited that format.
  """

  @manifest_dir Path.expand("../../../../priv/custom_formats", __DIR__)

  @manifest_files ~w(languages.exs)

  for file <- @manifest_files do
    @external_resource Path.join(@manifest_dir, file)
  end

  @entries (for file <- @manifest_files do
              path = Path.join(@manifest_dir, file)
              {entries, _bindings} = Code.eval_file(path)

              unless is_list(entries) do
                raise CompileError,
                  description:
                    "Custom format manifest #{file} must return a list, got: #{inspect(entries)}"
              end

              for entry <- entries do
                unless is_map(entry) and is_binary(Map.get(entry, :slug)) and
                         is_binary(Map.get(entry, :name)) and
                         is_list(Map.get(entry, :patterns)) and
                         Map.get(entry, :patterns) != [] and
                         Enum.all?(entry.patterns, &is_binary/1) do
                  raise CompileError,
                    description:
                      "Custom format manifest #{file} contains a malformed entry: " <>
                        inspect(entry)
                end

                for pattern <- entry.patterns do
                  case :re.compile(pattern, [:caseless, :unicode]) do
                    {:ok, _} ->
                      :ok

                    {:error, {reason, at}} ->
                      raise CompileError,
                        description:
                          "Custom format #{entry.slug} has an uncompilable pattern " <>
                            "#{inspect(pattern)}: #{List.to_string(reason)} at #{at}"
                  end
                end
              end

              entries
            end)
           |> List.flatten()

  @slugs Enum.map(@entries, & &1.slug)

  if length(@slugs) != length(Enum.uniq(@slugs)) do
    raise CompileError,
      description:
        "Duplicate custom format slug in the manifest: " <>
          inspect(@slugs -- Enum.uniq(@slugs))
  end

  @doc "All built-in format entries, in manifest order."
  @spec all() :: [map()]
  def all, do: @entries

  @doc "Every built-in slug."
  @spec slugs() :: [String.t()]
  def slugs, do: @slugs

  @doc "The built-in entry for `slug`, or nil."
  @spec get(String.t()) :: map() | nil
  def get(slug) when is_binary(slug), do: Enum.find(@entries, &(&1.slug == slug))
  def get(_), do: nil
end
