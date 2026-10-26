defmodule Mydia.Library.ReleaseParser.Vocabulary do
  @moduledoc """
  Compile-time loader for `priv/release_parser/*.exs` vocabulary files.

  Each vocabulary file returns a list of `%VocabularyEntry{}` terms. We
  load them with `Code.eval_file/1` at compile time (NOT `:file.consult/1`
  — the files contain struct literals, which `:file.consult/1` can't
  read). Each loaded file is registered as an `@external_resource` so
  `mix compile` re-runs this module when any vocabulary file changes
  during dev, giving us the "add a codec, recompile, done" workflow the
  plan calls for.

  The alias→entries index is precomputed at compile time, so runtime
  `lookup/1` is a single `Map.get/2`. Aliases are normalized to
  lowercase; lookup downcases the input before the hit.
  """

  alias Mydia.Library.ReleaseParser.VocabularyEntry

  @vocab_dir Path.expand("../../../../priv/release_parser", __DIR__)

  @vocab_files ~w(
    codecs.exs
    sources.exs
    hdr.exs
    audio.exs
    languages.exs
    streaming_services.exs
    release_groups.exs
    revisions.exs
  )

  for file <- @vocab_files do
    @external_resource Path.join(@vocab_dir, file)
  end

  @entries (for file <- @vocab_files do
              path = Path.join(@vocab_dir, file)

              {entries, _bindings} = Code.eval_file(path)

              unless is_list(entries) do
                raise CompileError,
                  description:
                    "Vocabulary file #{file} must return a list, got: #{inspect(entries)}"
              end

              for entry <- entries do
                unless match?(%VocabularyEntry{}, entry) do
                  raise CompileError,
                    description:
                      "Vocabulary file #{file} contains a non-%VocabularyEntry{} term: " <>
                        inspect(entry)
                end
              end

              entries
            end)
           |> List.flatten()

  # Build the alias→entries index. Aliases within a single entry that
  # collide once downcased (e.g. both `"BluRay"` and `"BLURAY"`) must not
  # add the entry twice, so we dedupe per-entry keys before merging.
  @index Enum.reduce(@entries, %{}, fn entry, acc ->
           entry.aliases
           |> Enum.map(&String.downcase/1)
           |> Enum.uniq()
           |> Enum.reduce(acc, fn key, inner ->
             Map.update(inner, key, [entry], fn list -> list ++ [entry] end)
           end)
         end)

  @doc """
  All loaded vocabulary entries across every file. Useful for tests and
  diagnostics; runtime callers should prefer `lookup/1`.
  """
  @spec all() :: [VocabularyEntry.t()]
  def all, do: @entries

  @doc """
  Look up vocabulary entries that match a token value (case-insensitive,
  except for `uppercase_only` entries). Returns `[]` for unknown tokens.
  """
  @spec lookup(String.t()) :: [VocabularyEntry.t()]
  def lookup(token_value) when is_binary(token_value) do
    case Map.get(@index, String.downcase(token_value), []) do
      [] ->
        []

      entries ->
        capitals? = String.upcase(token_value) == token_value
        Enum.filter(entries, &(capitals? or not &1.uppercase_only))
    end
  end

  @doc """
  Source file paths registered as `@external_resource`. Exposed for
  documentation / introspection; not used at runtime.
  """
  @spec source_files() :: [String.t()]
  def source_files do
    Enum.map(@vocab_files, &Path.join(@vocab_dir, &1))
  end
end
