defmodule TypeSafe.NoulAnswer do
  @moduledoc """
  The answer to a `TypeSafe.Noul`: `noul` is the probability of yes, from 0 to 1.

  A value near 0.5 means yes and no are about equally likely, not "somewhat yes".
  Noul answers carry no separate confidence.
  """

  defstruct [:noul]

  @type t :: %__MODULE__{noul: float()}

  @doc "Whether the probability of yes is above `threshold` (default 0.5)."
  @spec yes?(t(), float()) :: boolean()
  def yes?(%__MODULE__{noul: noul}, threshold \\ 0.5), do: noul > threshold
end

defmodule TypeSafe.ChoiceAnswer do
  @moduledoc """
  The answer to a `TypeSafe.Choice`.

    * `choice` - the most probable option, with the same key (atom or string) the
      question used
    * `probabilities` - every option mapped to its probability; they sum to 1
    * `confidence` - how concentrated the distribution is, from 0 to 1. It is not
      the probability that the choice is right.
  """

  defstruct [:choice, :probabilities, :confidence]

  @type t :: %__MODULE__{
          choice: TypeSafe.Choice.option(),
          probabilities: %{TypeSafe.Choice.option() => float()},
          confidence: float()
        }

  @doc "The options with their probabilities, most probable first."
  @spec ranked(t()) :: [{TypeSafe.Choice.option(), float()}]
  def ranked(%__MODULE__{probabilities: probabilities}) do
    Enum.sort_by(probabilities, fn {_option, p} -> p end, :desc)
  end
end

defmodule TypeSafe.ScoreAnswer do
  @moduledoc """
  The answer to a `TypeSafe.Score`.

    * `score` - the probability-weighted level index; with four levels it lies
      between 0 and 3 and can fall between levels
    * `legend` - each level index mapped to the description the question gave it
    * `probabilities` - each level index mapped to its probability
    * `confidence` - how concentrated the distribution is, from 0 to 1

  Use `score` to compare against thresholds, not to recover an exact quantity
  between two levels.
  """

  defstruct [:score, :legend, :probabilities, :confidence]

  @type t :: %__MODULE__{
          score: float(),
          legend: %{non_neg_integer() => TypeSafe.json()},
          probabilities: %{non_neg_integer() => float()},
          confidence: float()
        }

  @doc "The score scaled to 0..1, where 0 is the first level and 1 the last."
  @spec normalized(t()) :: float()
  def normalized(%__MODULE__{score: score, legend: legend}) when map_size(legend) > 1,
    do: score / (map_size(legend) - 1)

  @doc "The index of the most probable level."
  @spec level(t()) :: non_neg_integer()
  def level(%__MODULE__{probabilities: probabilities}) do
    probabilities |> Enum.max_by(fn {_level, p} -> p end) |> elem(0)
  end
end

defmodule TypeSafe.Answer do
  @moduledoc false
  # Decodes the wire answers into structs, mapping keys back to what the
  # questions used. Returns {:error, path} naming the first field that is
  # missing or malformed, so a bad response is reported rather than half-read.

  alias TypeSafe.{Choice, ChoiceAnswer, Noul, NoulAnswer, Score, ScoreAnswer}

  def decode_all(questions, answers) when is_map(answers) do
    Enum.reduce_while(questions, {:ok, %{}}, fn {key, question}, {:ok, acc} ->
      id = to_string(key)

      case Map.fetch(answers, id) do
        {:ok, raw} ->
          case decode(question, raw) do
            {:ok, answer} -> {:cont, {:ok, Map.put(acc, key, answer)}}
            {:error, field} -> {:halt, {:error, "answers.#{id}.#{field}"}}
          end

        :error ->
          {:halt, {:error, "answers.#{id}"}}
      end
    end)
  end

  def decode_all(_questions, _answers), do: {:error, "answers"}

  defp decode(%Noul{}, %{"type" => "noul", "noul" => p}) when is_number(p),
    do: {:ok, %NoulAnswer{noul: p / 1}}

  defp decode(%Noul{}, _raw), do: {:error, "noul"}

  defp decode(%Choice{criteria: options}, %{"type" => "choice"} = raw) do
    by_name = Map.new(options, fn {option, _description} -> {to_string(option), option} end)
    option = fn name -> Map.get(by_name, name, name) end

    with {:ok, choice} <- fetch(raw, "choice", &is_binary/1),
         {:ok, probabilities} <- fetch(raw, "probabilities", &probabilities?/1),
         {:ok, confidence} <- fetch(raw, "confidence", &is_number/1) do
      {:ok,
       %ChoiceAnswer{
         choice: option.(choice),
         probabilities: Map.new(probabilities, fn {name, p} -> {option.(name), p / 1} end),
         confidence: confidence / 1
       }}
    end
  end

  defp decode(%Choice{}, _raw), do: {:error, "type"}

  defp decode(%Score{}, %{"type" => "score"} = raw) do
    with {:ok, score} <- fetch(raw, "score", &is_number/1),
         {:ok, legend} <- fetch(raw, "legend", &is_map/1),
         {:ok, probabilities} <- fetch(raw, "probabilities", &probabilities?/1),
         {:ok, confidence} <- fetch(raw, "confidence", &is_number/1),
         {:ok, legend} <- index_keys(legend, "legend"),
         {:ok, probabilities} <- index_keys(probabilities, "probabilities") do
      {:ok,
       %ScoreAnswer{
         score: score / 1,
         legend: legend,
         probabilities: Map.new(probabilities, fn {level, p} -> {level, p / 1} end),
         confidence: confidence / 1
       }}
    end
  end

  defp decode(%Score{}, _raw), do: {:error, "type"}

  # A raw-map question of a type this client predates: hand back the raw answer.
  defp decode(%{}, raw) when is_map(raw), do: {:ok, raw}
  defp decode(%{}, _raw), do: {:error, "type"}

  defp fetch(raw, field, valid?) do
    case Map.fetch(raw, field) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: {:error, field}
      :error -> {:error, field}
    end
  end

  defp probabilities?(map), do: is_map(map) and Enum.all?(map, fn {_k, p} -> is_number(p) end)

  defp index_keys(map, field) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Integer.parse(key) do
        {index, ""} when index >= 0 -> {:cont, {:ok, Map.put(acc, index, value)}}
        _other -> {:halt, {:error, "#{field}.#{key}"}}
      end
    end)
  end
end
