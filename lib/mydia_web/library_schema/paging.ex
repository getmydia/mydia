defmodule MydiaWeb.LibrarySchema.Paging do
  @moduledoc """
  The `first` and `after` rules every Library API connection shares, and its cost.

  `first` reaches Ecto's `limit`, where 0 and negative values are invalid or
  surprising, so they are refused rather than clamped: a client that asks for 0
  has a bug worth surfacing. Pricing is the exception. Complexity analysis runs
  before any resolver refuses a bad `first`, so the cost clamps it to 1..cap; a
  zero or negative cost would offset expensive sibling fields.
  """

  alias Mydia.LibraryApi.Cursor

  @doc "Validates `first`, defaulting nil."
  @spec page_size(term(), pos_integer(), pos_integer()) :: {:ok, pos_integer()} | {:error, map()}
  def page_size(nil, default, _cap), do: {:ok, default}

  def page_size(first, _default, cap) when is_integer(first) and first >= 1 and first <= cap,
    do: {:ok, first}

  def page_size(first, _default, cap) when is_integer(first) do
    {:error,
     %{
       message: "first must be between 1 and #{cap}, got #{first}",
       extensions: %{code: "INVALID_INPUT"}
     }}
  end

  def page_size(_first, _default, _cap) do
    {:error, %{message: "first must be an integer", extensions: %{code: "INVALID_INPUT"}}}
  end

  @doc "Decodes an `after` cursor, passing nil through."
  @spec decode_cursor(String.t() | nil) ::
          {:ok, {DateTime.t(), String.t()} | nil} | {:error, map()}
  def decode_cursor(nil), do: {:ok, nil}

  def decode_cursor(cursor) do
    case Cursor.decode(cursor) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %{message: "Invalid cursor", extensions: %{code: "INVALID_INPUT"}}}
    end
  end

  @doc "A connection field's complexity: `first` clamped to 1..cap, times its child's."
  @spec cost(map(), pos_integer(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  def cost(args, default, cap, child_complexity) do
    first = (Map.get(args, :first) || default) |> min(cap) |> max(1)
    first * child_complexity
  end
end
