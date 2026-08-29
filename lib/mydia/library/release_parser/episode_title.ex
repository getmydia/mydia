defmodule Mydia.Library.ReleaseParser.EpisodeTitle do
  @moduledoc """
  Recovers the episode title that follows the `SxxEyy` marker in a filename.

  `TitleAssembler.assemble/2` is not reusable here. It renders tokens whose
  byte offset falls *before* a boundary, because it exists to recover the show
  title preceding the episode marker. The episode title is on the other side of
  that anchor.

  The rule is the classifier's own output. In the metadata zone a token
  receives candidates only when an anchor or the vocabulary recognised it, so
  resolution, source, codec and release-group tokens carry candidates while
  ordinary title words carry none. The unclassified run immediately after the
  marker is therefore exactly the episode title, and a scene release with no
  title yields nothing at all.

  Kept deliberately separate from `TitleAssembler`: the show-title path is
  covered by the corpus and parity gates, and widening it to serve a second
  caller would put those gates at risk for no gain.
  """

  alias Mydia.Library.ReleaseParser.{Classifier, Token, Tokenizer}

  @marker_labels [:episode_marker, :season_marker]

  # `-` is not a tokenizer delimiter, so a dash-separated name leaves a bare
  # `-` token at either end of the title run.
  @leading_junk ~r/\A[\s\-_.,:;!?'"]+/u
  @trailing_junk ~r/[\s\-_.,:;!?'"]+\z/u

  @doc """
  The episode title in `filename`, or `nil` when there is none to recover.
  """
  @spec extract(String.t() | nil) :: String.t() | nil
  def extract(nil), do: nil

  def extract(filename) when is_binary(filename) do
    anchors = Tokenizer.anchor_positions(filename)

    filename
    |> Tokenizer.tokenize()
    |> Classifier.classify(anchors)
    |> after_episode_marker()
    |> Enum.take_while(&unclassified?/1)
    |> render()
  end

  # Drops everything up to and including the marker. `S04` and `E01` can arrive
  # as two adjacent tokens, hence the second drop_while rather than one split.
  defp after_episode_marker(tokens) do
    case Enum.split_while(tokens, &(not marker?(&1))) do
      {_before, []} -> []
      {_before, [_marker | rest]} -> Enum.drop_while(rest, &marker?/1)
    end
  end

  defp marker?(%Token{candidates: candidates}) do
    Enum.any?(candidates, &(&1.label in @marker_labels))
  end

  defp unclassified?(%Token{candidates: []}), do: true
  defp unclassified?(%Token{}), do: false

  defp render([]), do: nil

  defp render(tokens) do
    tokens
    |> Enum.map_join(" ", & &1.value)
    |> String.replace(@leading_junk, "")
    |> String.replace(@trailing_junk, "")
    |> nil_if_empty()
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value
end
