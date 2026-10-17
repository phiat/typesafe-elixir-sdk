# TypeSafe System One API for Elixir

[![Hex.pm](https://img.shields.io/hexpm/v/typesafe_ex.svg)](https://hex.pm/packages/typesafe_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-8e7ce6.svg)](https://hexdocs.pm/typesafe_ex)
[![Elixir](https://img.shields.io/badge/elixir-~%3E%201.15-4e2a8e.svg)](https://github.com/phiat/typesafe-elixir-sdk/blob/main/mix.exs)
[![License: MIT](https://img.shields.io/hexpm/l/typesafe_ex.svg)](LICENSE)

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
  [{:typesafe_ex, "~> 0.2"}]
end
```

It depends on `req`, `jason` and `telemetry`.

## Questions and answers

| Builder | Asks | Answer struct |
| --- | --- | --- |
| `TypeSafe.noul/2` | whether a condition holds | `NoulAnswer`: `noul`, the probability of yes |
| `TypeSafe.choice/2` | which one of a defined set | `ChoiceAnswer`: `choice`, `probabilities`, `confidence` |
| `TypeSafe.score/2` | how far along ordered levels | `ScoreAnswer`: `score`, `legend`, `probabilities`, `confidence` |
| `TypeSafe.box/1` | where something is in an [image](#images-and-box-questions) | `BoxAnswer`: `top`, `bottom`, `left`, `right`, `confidence` |

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

Malformed questions raise `ArgumentError` before anything is sent. That includes a
Choice with more than 255 options and a Score with more than 10 levels, which the API
refuses.

## Images and Box questions

`TypeSafe.box/1` finds something in an image and answers with a box. Images work with
any question type: a Noul can ask whether a person is in a photo, a Choice what kind
of document a scan is.

A `TypeSafe.Image` is a PNG or JPEG. It stands in a request by its *reference*, a
string. Put the image where it belongs in the state or in a question, and pass it in
`:images`:

```elixir
photo = TypeSafe.Image.from_file!("kitchen.jpg")

{:ok, response} =
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

if TypeSafe.NoulAnswer.yes?(response.answers.mug_present) do
  TypeSafe.BoxAnswer.pixels(response.answers.mug, 1024, 768)
  #=> {left, top, right, bottom} for a 1024x768 image
end
```

- **Box needs `jev-1.14.0` or later**, or the `jev-preview` alias. `jev-latest` stays
  on `jev-1.13.0` until 1.14 is promoted, and a Box question sent to it is rejected
  with a plain `400`.
- **Edges are fractions.** `left` and `right` are fractions of the width, `top` and
  `bottom` of the height, from the top-left corner. `BoxAnswer.pixels/3` scales them
  to an image of known size.
- **A box always comes back.** There is no "not found" answer, so a target that isn't
  there still gets a box, with low confidence. Ask a Noul about presence in the same
  call, as above, and ignore the box when it is low. `confidence` can be `nil`, which
  the API allows.
- **Images work on `jev-1.13.0` too.** They are billed as input tokens, and each place
  a reference is used sends another copy of the image.
- **Reference the image by name or by value.** The state can be `%{photo: photo}` with
  questions saying `` `photo` ``, or you can interpolate the image into a string:
  `"the person in #{badge}"`.
- **Mistakes are caught before sending**, as `ArgumentError`: an image nothing refers
  to, a reference whose image was never attached, and a Box question with no image.
  The API would otherwise answer with an opaque `400`, or for the last two, silently
  answer about text and not the picture.
- **Limits.** Each side must be 280 to 1568 pixels, a file at most 16 MiB, and the
  request at most 32 MiB. Images outside that are rejected by the API (`400`, or `413`
  as `:payload_too_large`), not resized. Rotate pixels upright first: EXIF orientation
  is ignored. Convert GIF, WebP and HEIC to PNG or JPEG; `TypeSafe.Image` refuses them.
- **Transport.** Images go as a `multipart/form-data` upload, which the API recommends
  over base64, and the `TypeSafe-Danger-Zone-Images: true` header it requires is added
  for you. Images are marked experimental by TypeSafe and may change.

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
such as `"jev-1.14.0"` once you have. The aliases move when a new release ships.

| Model | Notes |
| --- | --- |
| `jev-1.14.0` | the newest release (14 October 2026); the only one with Box questions |
| `jev-1.13.0` | the previous release |
| `jev-latest` | the newest *stable* release; the default. `jev-1.13.0` as of 16 October 2026 |
| `jev-preview` | the newest release of any kind. `jev-1.14.0` as of 16 October 2026 |

All models take 64k tokens per request and 32k per question. `TypeSafe.models/1` lists
what the account can send; versioned ids work whether or not they're listed. For a
state that doesn't fit, `long_context: true` raises both limits to 262k tokens at the
same price per token, but slower and less accurate.

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
| `:compression` | | `false`; or `:gzip`, `:zstd`, [see below](#compression) |
| `:headers` | | extra request headers |
| `:req_options` | | merged into the `Req` request last |

A missing key doesn't stop `new/1`, so an app can boot without one. Calls then return
`{:error, %TypeSafe.Error{reason: :no_api_key}}` without making a request.
`TypeSafe.configured?/1` tells you which case you are in.

`system_one/4` can override `:model`, `:timeout`, `:retry`, `:compression` and `:headers`
per call. It also takes `:images` to send [images](#images-and-box-questions),
`:long_context` to raise the context limits, and `:extra_body` for top-level fields the
API adds later.

## Compression

The API accepts request bodies compressed with gzip or zstd. It pays on large states,
such as a long document or a chat log, and saves upload time on a slow link. It is off
unless you ask:

```elixir
client = TypeSafe.new(compression: :gzip)   # every call; or :zstd
TypeSafe.system_one(client, state, questions, compression: false)   # override one call
```

- **Bodies under 1 KiB are sent as they are**, as the official SDKs do. Larger ones
  get a `Content-Encoding` header.
- **`:zstd` needs Erlang/OTP 28 or later**, which has it built in. On an older OTP it
  raises an `ArgumentError` naming the fix; `:gzip` works everywhere.
- **Retries resend the same compressed bytes.** The body is built and compressed once
  per call, and handed to `Req` as final bytes.
- **Requests with images** are compressed whole. The images won't shrink, since PNG
  and JPEG are already compressed, so it only helps when the state is large text.

## Errors and retries

Failures return `{:error, %TypeSafe.Error{}}`, and `system_one!/4` raises the same
struct. Each error has a `reason`, the HTTP `status`, the server's `message`, and the
`x-typesafe-request-id` as `request_id`.

| `reason` | When |
| --- | --- |
| `:no_api_key` | no key configured; no request made |
| `:bad_request`, `:authentication`, `:permission_denied`, `:not_found` | 400, 401, 403, 404 |
| `:payload_too_large` | 413; the request is over 32 MiB, as it can be with images |
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
    "model" => "jev-1.14.0",
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
