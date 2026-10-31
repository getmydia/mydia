defmodule Mydia.Settings.QualityProfile.FreeleechPreference do
  @moduledoc """
  The `freeleech_preference` quality-profile setting: `"ignore"` (the default,
  also what an absent key means) or `"prefer"`.

  It is a preference, not a limit. With `"prefer"`, `Mydia.Indexers.SearchScorer`
  adds a freeleech bonus to a release's ranking score; nothing is removed and the
  file-scale quality score never sees it. See `lib/mydia/indexers/README.md`
  ("Limits vs preferences").
  """

  import Ecto.Changeset

  @values ~w(ignore prefer)

  @doc "The allowed values, default first."
  @spec values() :: [String.t()]
  def values, do: @values

  @doc "Whether the profile asks for freeleech releases to rank higher."
  @spec prefer?(map() | nil) :: boolean()
  def prefer?(%{quality_standards: %{} = standards}),
    do: Map.get(standards, :freeleech_preference) == "prefer"

  def prefer?(_profile), do: false

  @doc "Adds a `quality_standards` error when the value is not one of `values/0`."
  @spec validate(Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def validate(changeset, standards) do
    case Map.get(standards, :freeleech_preference) do
      value when value in [nil | @values] ->
        changeset

      _ ->
        add_error(
          changeset,
          :quality_standards,
          "freeleech_preference must be one of: #{Enum.join(@values, ", ")}"
        )
    end
  end
end
