defmodule TypeSafe.Response do
  @moduledoc """
  The result of `TypeSafe.system_one/4`.

    * `answers` - one answer per question, under the same key the question used. With
      atom keys you can write `response.answers.team.choice`.
    * `model` - the versioned model that answered, such as `"jev-1.13.0"`, even when
      the request named an alias like `"jev-latest"`. Log it next to anything you
      store, so a threshold can be traced to the model it was tuned on.
    * `usage` - `%{input_tokens: n, output_tokens: n}`. Only input tokens are billed.
    * `request_id` - the `x-typesafe-request-id` header, for support requests.
    * `body` - the decoded JSON body, for fields this client does not know yet.
  """

  defstruct [:model, :answers, :usage, :request_id, :body]

  @type answer ::
          TypeSafe.NoulAnswer.t() | TypeSafe.ChoiceAnswer.t() | TypeSafe.ScoreAnswer.t() | map()
  @type t :: %__MODULE__{
          model: String.t(),
          answers: %{(atom() | String.t()) => answer()},
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
          request_id: String.t() | nil,
          body: map()
        }

  @doc false
  def decode(body, questions, request_id) do
    with {:ok, model} <- field(body, "model", &is_binary/1),
         {:ok, usage} <- usage(body),
         {:ok, answers} <- TypeSafe.Answer.decode_all(questions, body["answers"]) do
      {:ok,
       %__MODULE__{
         model: model,
         answers: answers,
         usage: usage,
         request_id: request_id,
         body: body
       }}
    end
  end

  defp usage(%{"usage" => %{"input_tokens" => input, "output_tokens" => output}})
       when is_integer(input) and is_integer(output),
       do: {:ok, %{input_tokens: input, output_tokens: output}}

  defp usage(_body), do: {:error, "usage"}

  defp field(body, name, valid?) do
    case body do
      %{^name => value} -> if valid?.(value), do: {:ok, value}, else: {:error, name}
      _missing -> {:error, name}
    end
  end
end

defmodule TypeSafe.Model do
  @moduledoc "A model name the account can send, from `TypeSafe.models/1`."

  defstruct [:name, :description, :release_date]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          release_date: DateTime.t() | String.t() | nil
        }

  @doc false
  def decode(%{"name" => name} = raw) when is_binary(name) do
    release_date =
      case raw["release_date"] do
        date when is_binary(date) ->
          case DateTime.from_iso8601(date) do
            {:ok, datetime, _offset} -> datetime
            {:error, _} -> date
          end

        other ->
          other
      end

    {:ok, %__MODULE__{name: name, description: raw["description"], release_date: release_date}}
  end

  def decode(_raw), do: {:error, "models.name"}
end
