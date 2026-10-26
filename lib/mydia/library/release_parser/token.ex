defmodule Mydia.Library.ReleaseParser.Token do
  @moduledoc """
  One lexical unit produced by the tokenizer.

  Positions are **byte offsets** into the normalized input, not grapheme
  indices. The tokenizer guarantees that `:binary.part(input, byte_offset,
  byte_length)` round-trips to `value`. This is non-negotiable: the V2
  Frieren S02E0X regression came from mixing byte and grapheme indices
  with multibyte filenames.

  `candidates` is filled by the classifier in a later stage; the tokenizer
  itself leaves it as an empty list.
  """

  alias Mydia.Library.ReleaseParser.Candidate

  @enforce_keys [:value, :byte_offset, :byte_length]
  # `bracket_offset` is the byte offset of the opening bracket enclosing the
  # token (nil outside brackets), so tokens sharing it came from the same
  # `[...]` group. `[Web][MKV]` and `[Web MKV]` carry the same context but
  # not the same offset.
  defstruct [
    :value,
    :byte_offset,
    :byte_length,
    :bracket_context,
    :bracket_offset,
    candidates: []
  ]

  @type bracket_context :: nil | :bracket | :paren | :brace

  @type t :: %__MODULE__{
          value: String.t(),
          byte_offset: non_neg_integer(),
          byte_length: non_neg_integer(),
          bracket_context: bracket_context(),
          bracket_offset: non_neg_integer() | nil,
          candidates: [Candidate.t()]
        }

  @doc "End byte offset of this token (exclusive)."
  @spec end_offset(t()) :: non_neg_integer()
  def end_offset(%__MODULE__{byte_offset: o, byte_length: l}), do: o + l
end
