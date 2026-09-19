defmodule TypeSafe.Noul do
  @moduledoc """
  A yes/no question. The answer is the probability that the answer is yes.

  Build one with `TypeSafe.noul/2`. `criteria` optionally describes what a yes and
  a no mean, as `true:` and `false:` entries.
  """

  @enforce_keys [:instructions]
  defstruct [:instructions, criteria: nil]

  @type t :: %__MODULE__{
          instructions: TypeSafe.json(),
          criteria: %{optional(boolean()) => TypeSafe.json()} | nil
        }
end

defmodule TypeSafe.Choice do
  @moduledoc """
  A question that selects one option from a defined set.

  Build one with `TypeSafe.choice/2`. Options are atoms or strings and keep the
  order they were given in. The answer names the option with the same key, so an
  atom option comes back as that atom.
  """

  @enforce_keys [:instructions, :criteria]
  defstruct [:instructions, :criteria]

  @type option :: atom() | String.t()
  @type t :: %__MODULE__{
          instructions: TypeSafe.json(),
          criteria: [{option(), TypeSafe.json() | nil}]
        }
end

defmodule TypeSafe.Score do
  @moduledoc """
  A question that rates the state against ordered levels, worst or least first.

  Build one with `TypeSafe.score/2`. The answer's `score` is a probability-weighted
  level index, so with four levels it lies between 0 and 3.
  """

  @enforce_keys [:instructions, :criteria]
  defstruct [:instructions, :criteria]

  @type t :: %__MODULE__{instructions: TypeSafe.json(), criteria: [TypeSafe.json()]}
end

defmodule TypeSafe.Question do
  @moduledoc false
  # Building, validating and encoding questions. Validation raises ArgumentError:
  # a malformed question is a programming error, not a runtime condition.

  alias TypeSafe.{Choice, Noul, Score}

  def noul(instructions, criteria) do
    check_instructions!(instructions)

    criteria =
      Enum.map(criteria, fn
        {key, description} when key in [true, false, "true", "false"] ->
          {key in [true, "true"], check_json!(description, "Noul criteria")}

        {key, _description} ->
          raise ArgumentError, "Noul criteria keys must be true or false, got: #{inspect(key)}"
      end)

    %Noul{
      instructions: instructions,
      criteria: if(criteria == [], do: nil, else: Map.new(criteria))
    }
  end

  def choice(instructions, criteria) do
    check_instructions!(instructions)

    options =
      Enum.map(criteria, fn
        {option, description} ->
          {check_option!(option), check_json!(description, "Choice option")}

        option ->
          {check_option!(option), nil}
      end)

    if options == [], do: raise(ArgumentError, "a Choice needs at least one option")
    check_unique!(Enum.map(options, &elem(&1, 0)), "Choice options")
    %Choice{instructions: instructions, criteria: options}
  end

  def score(instructions, levels) when is_list(levels) do
    check_instructions!(instructions)

    if length(levels) < 2 do
      raise ArgumentError, "a Score needs at least two levels, got: #{length(levels)}"
    end

    %Score{
      instructions: instructions,
      criteria: Enum.map(levels, &check_json!(&1, "Score level"))
    }
  end

  def score(_instructions, levels) do
    raise ArgumentError, "Score levels must be a list, got: #{inspect(levels)}"
  end

  @doc false
  # Validates a questions map and returns it as [{original_key, question}].
  def check_all!(questions) when is_map(questions) and map_size(questions) > 0 do
    pairs = Map.to_list(questions)

    Enum.each(pairs, fn
      {key, _question} when not (is_atom(key) or is_binary(key)) ->
        raise ArgumentError, "question ids must be atoms or strings, got: #{inspect(key)}"

      {_key, %struct{}} when struct in [Noul, Choice, Score] ->
        :ok

      {_key, %{} = raw} when is_map_key(raw, "type") or is_map_key(raw, :type) ->
        :ok

      {key, other} ->
        raise ArgumentError,
              "question #{inspect(key)} must be built with TypeSafe.noul/2, choice/2 or score/2 " <>
                "(or be a raw map with a \"type\"), got: #{inspect(other)}"
    end)

    check_unique!(Enum.map(pairs, &elem(&1, 0)), "question ids")
    pairs
  end

  def check_all!(questions) do
    raise ArgumentError, "questions must be a non-empty map, got: #{inspect(questions)}"
  end

  @doc false
  def to_json(%Noul{instructions: instructions, criteria: nil}),
    do: %{"type" => "noul", "instructions" => instructions}

  def to_json(%Noul{instructions: instructions, criteria: criteria}) do
    criteria = for {key, description} <- criteria, into: %{}, do: {to_string(key), description}
    %{"type" => "noul", "instructions" => instructions, "criteria" => criteria}
  end

  # Option order is part of what the model reads, so it is kept on the wire.
  def to_json(%Choice{instructions: instructions, criteria: options}) do
    criteria =
      Jason.OrderedObject.new(
        for {option, description} <- options, do: {to_string(option), description}
      )

    %{"type" => "choice", "instructions" => instructions, "criteria" => criteria}
  end

  def to_json(%Score{instructions: instructions, criteria: levels}),
    do: %{"type" => "score", "instructions" => instructions, "criteria" => levels}

  def to_json(%{} = raw), do: raw

  defp check_instructions!(instructions) do
    valid? =
      (is_binary(instructions) and String.trim(instructions) != "") or is_map(instructions) or
        (is_list(instructions) and instructions != [])

    valid? ||
      raise ArgumentError,
            "instructions must be a non-empty string, map or list, got: #{inspect(instructions)}"
  end

  defp check_option!(option) when is_atom(option) and option not in [nil, true, false], do: option
  defp check_option!(option) when is_binary(option) and option != "", do: option

  defp check_option!(option) do
    raise ArgumentError,
          "Choice options must be atoms or non-empty strings, got: #{inspect(option)}"
  end

  defp check_json!(value, _what)
       when is_binary(value) or is_nil(value) or is_map(value) or is_list(value),
       do: value

  defp check_json!(value, what) do
    raise ArgumentError,
          "#{what} descriptions must be strings, maps, lists or nil, got: #{inspect(value)}"
  end

  defp check_unique!(keys, what) do
    duplicates =
      keys |> Enum.map(&to_string/1) |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end)

    if duplicates != [] do
      raise ArgumentError,
            "#{what} must be unique, got duplicates: #{inspect(Enum.map(duplicates, &elem(&1, 0)))}"
    end
  end
end
