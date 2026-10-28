defmodule Mydia.Indexers.Cardigann.Parity.Ratchet do
  @moduledoc """
  The committed, shrink-only list of known engine divergences.

  The file holds one entry per `{definition, query, kind, field}` with a
  human reason. A divergence not in the file fails (`new`), an entry whose
  divergence no longer occurs fails (`stale`, so the file can only shrink as
  bugs are fixed), and an entry still carrying the `"TODO"` placeholder fails
  (`todo`, so nothing is accepted without an explanation).
  """

  alias Mydia.Indexers.Cardigann.Parity.Divergence

  @todo "TODO"

  defmodule Entry do
    @moduledoc "One accepted divergence and why it is accepted."
    @enforce_keys [:definition, :query, :kind, :reason]
    defstruct [:definition, :query, :kind, :field, :reason]

    @type t :: %__MODULE__{
            definition: String.t(),
            query: atom(),
            kind: Divergence.kind(),
            field: atom() | nil,
            reason: String.t()
          }

    @spec key(t()) :: Divergence.key()
    def key(%__MODULE__{} = e), do: {e.definition, e.query, e.kind, e.field}
  end

  @spec load!(Path.t()) :: [Entry.t()]
  def load!(path) do
    {list, _binding} = Code.eval_file(path)

    unless is_list(list), do: raise(ArgumentError, "#{path} must evaluate to a list")

    Enum.map(list, fn map ->
      reason = Map.get(map, :reason)

      if not is_binary(reason) or String.trim(reason) == "" do
        raise ArgumentError, "#{path}: entry #{inspect(map)} has a missing or blank reason"
      end

      %Entry{
        definition: Map.fetch!(map, :definition),
        query: Map.fetch!(map, :query),
        kind: Map.fetch!(map, :kind),
        field: Map.get(map, :field),
        reason: reason
      }
    end)
  end

  @spec check([Divergence.t()], [Entry.t()]) ::
          :ok | {:error, %{new: [Divergence.t()], stale: [Entry.t()], todo: [Entry.t()]}}
  def check(divergences, entries) do
    listed = MapSet.new(entries, &Entry.key/1)
    seen = MapSet.new(divergences, &Divergence.key/1)

    new = Enum.reject(divergences, &(Divergence.key(&1) in listed))
    stale = Enum.reject(entries, &(Entry.key(&1) in seen))
    todo = Enum.filter(entries, &(&1.reason == @todo))

    if new == [] and stale == [] and todo == [],
      do: :ok,
      else: {:error, %{new: new, stale: stale, todo: todo}}
  end

  @doc """
  Adds a placeholder divergence for every existing entry whose definition is not
  in `ran`, so rendering a partial run keeps the entries it did not look at.
  """
  @spec keep_unrun([Divergence.t()], [Entry.t()], [String.t()]) :: [Divergence.t()]
  def keep_unrun(divergences, existing, ran) do
    kept =
      for e <- existing, e.definition not in ran do
        %Divergence{definition: e.definition, query: e.query, kind: e.kind, field: e.field}
      end

    divergences ++ kept
  end

  @doc "Source for a ratchet file covering `divergences`, keeping reasons from `existing`."
  @spec render([Divergence.t()], [Entry.t()]) :: String.t()
  def render(divergences, existing) do
    reasons = Map.new(existing, &{Entry.key(&1), &1.reason})

    body =
      divergences
      |> Enum.map(&Divergence.key/1)
      |> Enum.uniq()
      |> Enum.sort_by(fn {d, q, k, f} -> {d, to_string(q), to_string(k), to_string(f)} end)
      |> Enum.map_join(",\n", fn {d, q, k, f} = key ->
        "  %{definition: #{inspect(d)}, query: #{inspect(q)}, kind: #{inspect(k)}, " <>
          "field: #{inspect(f)}, reason: #{inspect(Map.get(reasons, key, @todo))}}"
      end)

    # The file lives under test/, so the pre-commit `mix format` check reads it:
    # write it the way the formatter would.
    ("[\n" <> body <> if(body == "", do: "", else: "\n") <> "]\n")
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  @spec format_failure(%{new: [Divergence.t()], stale: [Entry.t()], todo: [Entry.t()]}) ::
          String.t()
  def format_failure(%{new: new, stale: stale, todo: todo}) do
    Enum.join(
      Enum.map(new, fn d ->
        "new divergence: #{label(d)}, native #{inspect(d.native)} vs wasm #{inspect(d.wasm)}"
      end) ++
        Enum.map(stale, &"fixed, delete this entry: #{label(&1)}") ++
        Enum.map(todo, &"annotate: #{label(&1)}"),
      "\n"
    )
  end

  defp label(%{definition: d, query: q, kind: :field, field: f}), do: "#{d}/#{q} field #{f}"
  defp label(%{definition: d, query: q, kind: k}), do: "#{d}/#{q} #{k}"
end
