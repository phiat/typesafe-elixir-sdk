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
  | `box/1` | where something is in an image (`TypeSafe.Image`) | `TypeSafe.BoxAnswer` - the box's four edges, as fractions |

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
    * `:compression` - `:gzip`, `:zstd` or `false` (the default): compress request
      bodies of 1 KiB or more. `:zstd` needs Erlang/OTP 28 or later.
    * `:headers` - extra request headers
    * `:req_options` - merged into the `Req` request last, for example
      `[plug: {Req.Test, MyApp.TypeSafe}]` in tests
  """

  alias TypeSafe.{Client, Error, Image, Model, Question, Response}

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
            TypeSafe.Noul.t()
            | TypeSafe.Choice.t()
            | TypeSafe.Score.t()
            | TypeSafe.Box.t()
            | map()
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
  A question that locates something in an image. The answer is a
  `TypeSafe.BoxAnswer`: the box's `top`, `bottom`, `left` and `right` edges, as
  fractions of the image.

      photo = TypeSafe.Image.from_file!("kitchen.jpg")

      TypeSafe.system_one(
        client,
        %{photo: photo},
        %{
          mug_present: TypeSafe.noul("Is there a coffee mug in `photo`?"),
          mug: TypeSafe.box("The coffee mug in `photo`")
        },
        model: "jev-1.14.0",
        images: [photo]
      )

  `instructions` says what to find: a phrase, not a yes/no question. Name the image
  by its key in the state, in backticks, or put the `TypeSafe.Image` in the
  instructions.

  A Box question needs `jev-1.14.0` or later, or `jev-preview`. Older models, and
  `jev-latest` while it still points at one, reject it with a plain 400. It always
  answers with a box, even when the target is absent, so ask a `noul/2` about
  presence in the same call and ignore the box when that comes back low.
  """
  @spec box(json()) :: TypeSafe.Box.t()
  def box(instructions), do: Question.box(instructions)

  @doc """
  Asks `questions` about `state` in one request.

  `state` is a string, or a map or list for structured context. Questions can
  refer to its parts by backticked path, such as `` `ticket.messages[0]` ``.

  Question ids can be atoms or strings. They name the answers and are never sent to
  the model, so the question itself has to carry its meaning.

  Options:

    * `:model` - overrides the client's model for this call
    * `:timeout`, `:retry`, `:headers`, `:compression` - override the client's for this
      call
    * `:images` - a list of `TypeSafe.Image` to send with the call. Something in the
      state or the questions has to refer to each one, and every reference has to
      be attached here; otherwise `ArgumentError` is raised before anything is
      sent. A `box/1` question needs one. The images header the API requires is
      added for you, and the request goes out as `multipart/form-data`.
    * `:long_context` - `true` raises the per-request and per-question context
      limits from 64k to 262k tokens. The price per token is the same, but the
      model is slower and less accurate, so use it only when the state doesn't fit.
    * `:extra_body` - extra top-level request fields, for API features this client
      predates

  A question map may also hold raw maps (`%{"type" => ..., ...}`), sent as they are.
  Their answers come back as raw maps.
  """
  @spec system_one(Client.t(), json(), questions(), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def system_one(%Client{} = client, state, questions, opts \\ []) do
    pairs = Question.check_all!(questions)

    opts =
      Keyword.validate!(opts, [
        :model,
        :extra_body,
        :timeout,
        :retry,
        :headers,
        :long_context,
        :compression,
        images: []
      ])

    if state in [nil, ""] do
      raise ArgumentError, "state must be a non-empty string, map or list"
    end

    questions_json =
      Map.new(pairs, fn {key, question} -> {to_string(key), Question.to_json(question)} end)

    images =
      Image.check_all!(
        opts[:images],
        Jason.encode!([state, questions_json]),
        Question.box?(pairs)
      )

    body =
      opts
      |> Keyword.get(:extra_body, %{})
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{
        "state" => state,
        "model" => opts[:model] || client.model,
        "questions" => questions_json
      })
      |> put_assets(images)

    with {:ok, body, request_id} <-
           Client.request(client, :post, "/v1/systemone", body, request_opts(opts, images)) do
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
  `"jev-1.14.0"` are accepted whether or not they are listed.
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

  # Each image is listed once under its reference, naming the multipart part that
  # holds it. Without images, an `assets` entry in `:extra_body` is left alone.
  defp put_assets(body, []), do: body

  defp put_assets(body, images) do
    assets =
      images
      |> Enum.with_index()
      |> Map.new(fn {image, index} ->
        {image.reference, %{"type" => "image", "part" => Image.part_name(index)}}
      end)

    Map.put(body, "assets", assets)
  end

  # What the client needs to send it: the headers the API wants for images and long
  # context (ahead of the caller's, so theirs win), and the images as file parts.
  defp request_opts(opts, images) do
    defaults =
      if(images == [], do: [], else: [{"typesafe-danger-zone-images", "true"}]) ++
        if opts[:long_context], do: [{"typesafe-danger-zone-long-context", "true"}], else: []

    files =
      images
      |> Enum.with_index()
      |> Enum.map(fn {image, index} ->
        name = Image.part_name(index)

        %{
          name: name,
          filename: "#{name}.#{Image.extension(image)}",
          content_type: Image.content_type(image),
          data: image.binary
        }
      end)

    opts
    |> Keyword.put(:headers, defaults ++ Enum.to_list(Keyword.get(opts, :headers, [])))
    |> Keyword.put(:multipart, if(files == [], do: nil, else: files))
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
