# TypeSafe System One API for Elixir

An Elixir client for [TypeSafe](https://docs.typesafe.ai/)'s System One API, the API
behind **Jev**. It is unofficial and not published by TypeSafe. Its behaviour follows
the official Python SDK:

- the same environment variables and defaults
- the same retry policy
- the same error classes

System One models don't generate text. You send some state and a map of typed
questions, and get back one typed answer per question, with probabilities your code
acts on.

```elixir
client = TypeSafe.new()   # reads TYPESAFE_API_KEY

{:ok, response} =
  TypeSafe.system_one(client, %{ticket: "I was charged twice. Please fix this ASAP."}, %{
    billing: TypeSafe.noul("Is this ticket about billing?"),
    tone: TypeSafe.choice("What is the customer's tone?", [:calm, :frustrated, :angry]),
    urgency: TypeSafe.score("How urgent is this ticket?", ["Can wait", "This week", "Today"])
  })

response.answers
#=> %{
#     billing: %TypeSafe.NoulAnswer{noul: 0.99},
#     tone: %TypeSafe.ChoiceAnswer{
#       choice: :frustrated,
#       probabilities: %{calm: 0.0, frustrated: 0.86, angry: 0.14},
#       confidence: 0.78
#     },
#     urgency: %TypeSafe.ScoreAnswer{
#       score: 1.99,
#       legend: %{0 => "Can wait", 1 => "This week", 2 => "Today"},
#       probabilities: %{0 => 0.0, 1 => 0.0, 2 => 1.0},
#       confidence: 0.99
#     }
#   }

response.model   #=> "jev-1.13.0"
response.usage   #=> %{input_tokens: 367, output_tokens: 75}
```

That is a real response from `jev-1.13.0`.

## Installation

```elixir
def deps do
  [{:typesafe_ex, "~> 0.1"}]
end
```

It depends on `req`, `jason` and `telemetry`.

## Questions and answers

| Builder | Asks | Answer struct |
| --- | --- | --- |
| `TypeSafe.noul/2` | whether a condition holds | `NoulAnswer`: `noul`, the probability of yes |
| `TypeSafe.choice/2` | which one of a defined set | `ChoiceAnswer`: `choice`, `probabilities`, `confidence` |
| `TypeSafe.score/2` | how far along ordered levels | `ScoreAnswer`: `score`, `legend`, `probabilities`, `confidence` |

A few details keep answers easy to use from Elixir:

- **Answers use the question's keys.** Answers come back under the ids the questions
  used, so atom ids allow `response.answers.team`.
- **Choice options keep their type and order.** An atom option comes back as the atom.
  Options are sent in the order you gave, since the order is part of what the model reads.
- **Score keys are integers.** Level indexes in `legend` and `probabilities` are
  integers, not the strings on the wire.
- **Helpers:**
  - `ChoiceAnswer.ranked/1` gives options by probability, useful for a "did you mean"
    prompt.
  - `ScoreAnswer.normalized/1` scales the score to 0..1.
  - `ScoreAnswer.level/1` gives the most probable level.
  - `NoulAnswer.yes?/2` compares the probability to a threshold.

```elixir
TypeSafe.choice("Which team should own this ticket?",
  billing: "Charges, invoices, refunds",
  technical: "Bugs, outages, integrations",
  unclear: "The ticket does not say enough to tell"
)

TypeSafe.noul("If the user wants to change the lights, do they want them on?",
  true: "Lights on or brighter",
  false: "Lights off or dimmer"
)
```

Instructions and descriptions can be maps or lists when structure makes a question
clearer. A raw map (`%{"type" => ..., ...}`) is sent as given, and its answer comes
back raw. That covers question types this client predates.

## Code owns the decision

Ask independent questions together: they share one read of the state and run in
parallel. Then let ordinary code apply the policy.

```elixir
%{team: team, security: security} = response.answers

cond do
  TypeSafe.NoulAnswer.yes?(security) -> {:route, :security}
  team.choice == :unclear or team.confidence < 0.5 -> {:route, :human}
  true -> {:route, team.choice}
end
```

`confidence` measures how concentrated the distribution is. It is not the probability
that the answer is right. Tune thresholds on your own data, and pin a versioned model
such as `"jev-1.13.0"` once you have. `jev-latest` moves when a new release ships.

For many items, run one call per item concurrently:

```elixir
tickets
|> Task.async_stream(&TypeSafe.system_one(client, %{ticket: &1}, questions), max_concurrency: 8)
|> Enum.map(fn {:ok, result} -> result end)
```

## Configuration

| Option to `new/1` | Environment variable | Default |
| --- | --- | --- |
| `:api_key` | `TYPESAFE_API_KEY` | none |
| `:base_url` | `TYPESAFE_BASE_URL` | `https://api.typesafe.ai` |
| `:model` | `TYPESAFE_DEFAULT_MODEL` | `jev-latest` |
| `:timeout` | | `10_000` ms per response |
| `:retry` | | see below |
| `:headers` | | extra request headers |
| `:req_options` | | merged into the `Req` request last |

A missing key doesn't stop `new/1`, so an app can boot without one. Calls then return
`{:error, %TypeSafe.Error{reason: :no_api_key}}` without making a request.
`TypeSafe.configured?/1` tells you which case you are in.

`system_one/4` can override `:model`, `:timeout`, `:retry` and `:headers` per call. It
also takes `:extra_body` for top-level fields the API adds later.

## Errors and retries

Failures return `{:error, %TypeSafe.Error{}}`, and `system_one!/4` raises the same
struct. Each error has a `reason`, the HTTP `status`, the server's `message`, and the
`x-typesafe-request-id` as `request_id`.

| `reason` | When |
| --- | --- |
| `:no_api_key` | no key configured; no request made |
| `:bad_request`, `:authentication`, `:permission_denied`, `:not_found` | 400, 401, 403, 404 |
| `:unprocessable_entity` | 422; the message lists each field, as `path: problem` |
| `:rate_limited`, `:overloaded`, `:server_error`, `:http_error` | 429, 529, other 5xx, anything else |
| `:timeout`, `:connection` | no response |
| `:invalid_response` | a 2xx missing a required field; the message names it |

Retries follow the official SDKs:

- **What is retried:** up to 2 retries on 408, 429 and every 5xx, and on timeouts and
  failed connections.
- **Backoff:** from 500 ms, doubling to 5 s, with 25% jitter.
- **Server waits:** `retry-after-ms` and `retry-after` are honoured.
- **Budget:** 30 s per call, including waits. A retry whose wait would pass the budget
  is not attempted.
- **Retry count:** each retry sends `x-typesafe-retry-count`.

Configure it with `retry: [max_retries: 5, budget: 60_000]`, or turn it off with
`retry: false`, on the client or per call. See `TypeSafe.Retry` for the options.

## Telemetry

Every request runs in a `:telemetry.span/3` named `[:typesafe, :request]`.

- **Metadata:** `method`, `path` and `model`.
- **On stop:** `result` (`:ok` or `:error`), `request_id`, and, on error, `reason` and
  `status`.

## Testing an app that uses it

Point the client at `Req.Test`:

```elixir
# config/test.exs
config :my_app, :typesafe, req_options: [plug: {Req.Test, MyApp.TypeSafe}]

# in a test
Req.Test.stub(MyApp.TypeSafe, fn conn ->
  Req.Test.json(conn, %{
    "model" => "jev-1.13.0",
    "answers" => %{"billing" => %{"type" => "noul", "noul" => 0.97}},
    "usage" => %{"input_tokens" => 100, "output_tokens" => 10}
  })
end)
```

## Developing

```sh
mix test                                         # unit tests, no network
TYPESAFE_API_KEY=... mix test --include integration   # also calls the live API
```

TypeSafe docs: [index](https://docs.typesafe.ai/llms.txt) ·
[primitives](https://docs.typesafe.ai/primitives) ·
[confidence](https://docs.typesafe.ai/confidence) ·
[HTTP API](https://docs.typesafe.ai/api)

## License

MIT. See [LICENSE](LICENSE).
