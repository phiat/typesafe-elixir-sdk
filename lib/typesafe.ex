defmodule TypeSafe do
  @moduledoc """
  An Elixir client for TypeSafe's System One API.

  System One models, such as Jev, don't generate text. You send some state and a map
  of typed questions, and get back one typed answer per question, with
  probabilities your code can act on:

  | Question | Answers | Answer |
  | --- | --- | --- |
  | `noul/2` | whether a condition holds | `TypeSafe.NoulAnswer` - probability of yes |
  | `choice/2` | which one of a defined set | `TypeSafe.ChoiceAnswer` - option, probabilities, confidence |
  | `score/2` | how far along described levels | `TypeSafe.ScoreAnswer` - weighted level, probabilities, confidence |

      client = TypeSafe.new()

      {:ok, response} =
        TypeSafe.system_one(client, %{ticket: "I was charged twice. Please fix this ASAP."}, %{
          billing: TypeSafe.noul("Is this ticket about billing?"),
          tone: TypeSafe.choice("What is the customer's tone?", [:calm, :frustrated, :angry]),
          urgency: TypeSafe.score("How urgent is this ticket?", ["Can wait", "This week", "Today"])
        })

      response.answers.billing.noul     #=> 0.97
      response.answers.tone.choice      #=> :frustrated
      response.answers.urgency.score    #=> 1.8

  Questions in one call share one read of the state and are answered in parallel,
  so ask independent questions together. Each answers without seeing the others.

  ## Configuration

  `new/1` reads these environment variables when the option is not given:

  | Option | Environment variable | Default |
  | --- | --- | --- |
  | `:api_key` | `TYPESAFE_API_KEY` | none - calls return `:no_api_key` |
  | `:base_url` | `TYPESAFE_BASE_URL` | `https://api.typesafe.ai` |
  | `:model` | `TYPESAFE_DEFAULT_MODEL` | `jev-latest` |

  It also takes these options:

    * `:timeout` - milliseconds to wait for each response (default 10_000)
    * `:retry` - see `TypeSafe.Retry`
    * `:headers` - extra request headers
    * `:req_options` - merged into the `Req` request last, for example
      `[plug: {Req.Test, MyApp.TypeSafe}]` in tests
  """

  alias TypeSafe.{Client, Error, Model, Question, Response}

  @typedoc "Anything that encodes to JSON: strings, numbers, booleans, nil, lists and maps."
  @type json ::
          String.t()
          | number()
          | boolean()
          | nil
          | [json()]
          | %{optional(atom() | String.t()) => json()}

  @type questions :: %{
          (atom() | String.t()) =>
            TypeSafe.Noul.t() | TypeSafe.Choice.t() | TypeSafe.Score.t() | map()
        }

  @doc """
  Builds a client. See the module documentation for the options.

  A missing API key is not an error here, so an app can boot without one. Calls
  return `{:error, %TypeSafe.Error{reason: :no_api_key}}` until one is set.
  """
  @spec new(keyword()) :: Client.t()
  def new(opts \\ []), do: Client.new(opts)

  @doc "Whether the client has an API key."
  @spec configured?(Client.t()) :: boolean()
  def configured?(%Client{api_key: api_key}), do: is_binary(api_key)

  @doc """
  A yes/no question. `criteria` optionally says what yes and no mean:

      TypeSafe.noul("If the user wants to change the lights, do they want them on?",
        true: "Lights on or brighter",
        false: "Lights off or dimmer"
      )

  `instructions` can be a string, or a map or list when structure makes the
  question clearer.
  """
  @spec noul(json(), keyword() | map()) :: TypeSafe.Noul.t()
  def noul(instructions, criteria \\ []), do: Question.noul(instructions, criteria)

  @doc """
  A question that picks one option. Options are atoms or strings, in order, with an
  optional description each:

      TypeSafe.choice("Which team should own this ticket?",
        billing: "Charges, invoices, refunds",
        technical: "Bugs, outages, integrations",
        unclear: "The ticket does not say enough to tell"
      )

      TypeSafe.choice("What is the tone?", [:calm, :frustrated, :angry])

  The answer's `choice` and `probabilities` use the same keys. Include a no-match
  option when nothing may fit, because the model must pick one of those given.
  """
  @spec choice(json(), keyword() | map() | [TypeSafe.Choice.option()]) :: TypeSafe.Choice.t()
  def choice(instructions, options), do: Question.choice(instructions, options)

  @doc """
  A question that rates the state against ordered levels, at least two, worst or
  least first. Each level should describe a concrete situation on its own:

      TypeSafe.score("How urgently does this ticket need a response?", [
        "Can wait: a question or feedback, nothing is blocked",
        "Soon: a problem with a workaround",
        "Today: something important is broken for the customer"
      ])
  """
  @spec score(json(), [json()]) :: TypeSafe.Score.t()
  def score(instructions, levels), do: Question.score(instructions, levels)

  @doc """
  Asks `questions` about `state` in one request.

  `state` is a string, or a map or list for structured context. Questions can
  refer to its parts by backticked path, such as `` `ticket.messages[0]` ``.

  Question ids can be atoms or strings. They name the answers and are never sent to
  the model, so the question itself has to carry its meaning.

  Options:

    * `:model` - overrides the client's model for this call
    * `:timeout`, `:retry`, `:headers` - override the client's for this call
    * `:extra_body` - extra top-level request fields, for API features this client
      predates

  A question map may also hold raw maps (`%{"type" => ..., ...}`), sent as they are.
  Their answers come back as raw maps.
  """
  @spec system_one(Client.t(), json(), questions(), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def system_one(%Client{} = client, state, questions, opts \\ []) do
    pairs = Question.check_all!(questions)
    opts = Keyword.validate!(opts, [:model, :extra_body, :timeout, :retry, :headers])

    if state in [nil, ""] do
      raise ArgumentError, "state must be a non-empty string, map or list"
    end

    body =
      opts
      |> Keyword.get(:extra_body, %{})
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{
        "state" => state,
        "model" => opts[:model] || client.model,
        "questions" =>
          Map.new(pairs, fn {key, question} -> {to_string(key), Question.to_json(question)} end)
      })

    with {:ok, body, request_id} <- Client.request(client, :post, "/v1/systemone", body, opts) do
      case Response.decode(body, pairs, request_id) do
        {:ok, response} -> {:ok, response}
        {:error, field} -> {:error, invalid_response(field, body, request_id)}
      end
    end
  end

  @doc "Like `system_one/4`, but returns the response or raises `TypeSafe.Error`."
  @spec system_one!(Client.t(), json(), questions(), keyword()) :: Response.t()
  def system_one!(client, state, questions, opts \\ []) do
    case system_one(client, state, questions, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  @doc """
  The model names the account can send, aliases included. Versioned ids such as
  `"jev-1.13.0"` are accepted whether or not they are listed.
  """
  @spec models(Client.t()) :: {:ok, [Model.t()]} | {:error, Error.t()}
  def models(%Client{} = client) do
    with {:ok, body, request_id} <- Client.request(client, :get, "/v1/models", nil, []) do
      with %{"models" => raw} when is_list(raw) <- body,
           {:ok, models} <- decode_models(raw) do
        {:ok, models}
      else
        {:error, field} -> {:error, invalid_response(field, body, request_id)}
        _other -> {:error, invalid_response("models", body, request_id)}
      end
    end
  end

  @doc "Like `models/1`, but returns the list or raises `TypeSafe.Error`."
  @spec models!(Client.t()) :: [Model.t()]
  def models!(client) do
    case models(client) do
      {:ok, models} -> models
      {:error, error} -> raise error
    end
  end

  defp decode_models(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn entry, {:ok, acc} ->
      case Model.decode(entry) do
        {:ok, model} -> {:cont, {:ok, [model | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, models} -> {:ok, Enum.reverse(models)}
      error -> error
    end
  end

  defp invalid_response(field, body, request_id) do
    %Error{
      reason: :invalid_response,
      status: 200,
      message: "invalid response data at #{inspect(field)}",
      body: body,
      request_id: request_id
    }
  end
end
