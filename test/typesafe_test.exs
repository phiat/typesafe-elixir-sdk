defmodule TypeSafeTest do
  use ExUnit.Case, async: true

  alias TypeSafe.{ChoiceAnswer, Error, NoulAnswer, ScoreAnswer}

  setup {Req.Test, :verify_on_exit!}

  defp client(opts \\ []) do
    [
      api_key: "test-key",
      retry: [backoff_initial: 0],
      req_options: [plug: {Req.Test, __MODULE__}, retry_log_level: false]
    ]
    |> Keyword.merge(opts)
    |> TypeSafe.new()
  end

  defp questions do
    %{
      team:
        TypeSafe.choice("Which team should own this ticket?",
          billing: "Charges, invoices, refunds",
          technical: "Bugs and outages",
          unclear: nil
        ),
      urgency: TypeSafe.score("How urgent is it?", ["Can wait", "Soon", "Today"]),
      refund: TypeSafe.noul("Is the customer asking for money back?", true: "Asks for money back")
    }
  end

  defp answers do
    %{
      "team" => %{
        "type" => "choice",
        "choice" => "billing",
        "probabilities" => %{"billing" => 0.9, "technical" => 0.08, "unclear" => 0.02},
        "confidence" => 0.84
      },
      "urgency" => %{
        "type" => "score",
        "score" => 1.5,
        "legend" => %{"0" => "Can wait", "1" => "Soon", "2" => "Today"},
        "probabilities" => %{"0" => 0.1, "1" => 0.3, "2" => 0.6},
        "confidence" => 0.5
      },
      "refund" => %{"type" => "noul", "noul" => 1}
    }
  end

  defp ok_body(answers \\ answers()) do
    %{
      "model" => "jev-1.13.0",
      "answers" => answers,
      "usage" => %{"input_tokens" => 312, "output_tokens" => 48}
    }
  end

  defp read_json(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw, objects: :ordered_objects), conn}
  end

  defp respond(conn, status, body, headers \\ []) do
    conn
    |> Plug.Conn.merge_resp_headers(headers)
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(body)
  end

  describe "system_one/4 request" do
    test "sends the state, the default model and typed questions, with options in order" do
      test = self()

      Req.Test.expect(__MODULE__, fn conn ->
        {body, conn} = read_json(conn)
        send(test, {:request, conn, body})
        respond(conn, 200, ok_body())
      end)

      assert {:ok, _response} =
               TypeSafe.system_one(client(), %{ticket: "Charged twice."}, questions())

      assert_received {:request, conn, body}

      assert conn.method == "POST"
      assert conn.request_path == "/v1/systemone"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      assert [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
      assert user_agent =~ ~r"^typesafe_ex/"
      assert Plug.Conn.get_req_header(conn, "x-typesafe-retry-count") == []

      assert body["model"] == "jev-latest"
      assert body["state"]["ticket"] == "Charged twice."
      team = body["questions"]["team"]
      assert team["type"] == "choice"

      assert Enum.map(team["criteria"].values, &elem(&1, 0)) == [
               "billing",
               "technical",
               "unclear"
             ]

      assert team["criteria"]["unclear"] == nil
      assert body["questions"]["urgency"]["criteria"] == ["Can wait", "Soon", "Today"]
      assert body["questions"]["refund"]["criteria"]["true"] == "Asks for money back"
      refute Map.has_key?(body["questions"]["refund"]["criteria"].values |> Map.new(), "false")
    end

    test "a call can override the model and add top-level fields" do
      test = self()

      Req.Test.expect(__MODULE__, fn conn ->
        {body, conn} = read_json(conn)
        send(test, {:body, body})
        respond(conn, 200, ok_body())
      end)

      TypeSafe.system_one!(client(model: "jev-preview"), "text", questions(),
        model: "jev-1.13.0",
        extra_body: %{beam_width: 4}
      )

      assert_received {:body, body}
      assert body["model"] == "jev-1.13.0"
      assert body["beam_width"] == 4
    end

    test "a noul without criteria sends none" do
      test = self()

      Req.Test.expect(__MODULE__, fn conn ->
        {body, conn} = read_json(conn)
        send(test, {:body, body})
        respond(conn, 200, ok_body(%{"q" => %{"type" => "noul", "noul" => 0.2}}))
      end)

      TypeSafe.system_one!(client(), "text", %{"q" => TypeSafe.noul("Is it?")})
      assert_received {:body, body}
      refute Map.has_key?(body["questions"]["q"].values |> Map.new(), "criteria")
    end
  end

  describe "system_one/4 response" do
    test "answers come back under the questions' own keys, options as the question gave them" do
      Req.Test.expect(__MODULE__, fn conn ->
        respond(conn, 200, ok_body(), [{"x-typesafe-request-id", "req_123"}])
      end)

      assert {:ok, response} = TypeSafe.system_one(client(), "Charged twice.", questions())

      assert response.model == "jev-1.13.0"
      assert response.request_id == "req_123"
      assert response.usage == %{input_tokens: 312, output_tokens: 48}

      assert %ChoiceAnswer{choice: :billing, confidence: 0.84} = response.answers.team

      assert response.answers.team.probabilities == %{
               billing: 0.9,
               technical: 0.08,
               unclear: 0.02
             }

      assert %ScoreAnswer{score: 1.5, confidence: 0.5} = response.answers.urgency
      assert response.answers.urgency.legend == %{0 => "Can wait", 1 => "Soon", 2 => "Today"}
      assert response.answers.urgency.probabilities == %{0 => 0.1, 1 => 0.3, 2 => 0.6}

      assert %NoulAnswer{noul: 1.0} = response.answers.refund
      assert is_float(response.answers.refund.noul)
    end

    test "string question ids and string options stay strings" do
      Req.Test.expect(__MODULE__, fn conn ->
        respond(
          conn,
          200,
          ok_body(%{
            "tone" => %{
              "type" => "choice",
              "choice" => "very angry",
              "probabilities" => %{"calm" => 0.1, "very angry" => 0.9},
              "confidence" => 0.7
            }
          })
        )
      end)

      response =
        TypeSafe.system_one!(client(), "text", %{
          "tone" => TypeSafe.choice("Tone?", ["calm", "very angry"])
        })

      assert response.answers["tone"].choice == "very angry"
    end

    test "a raw map question is sent as given and its answer returned raw" do
      raw_answer = %{"type" => "future", "value" => 3}

      Req.Test.expect(__MODULE__, fn conn ->
        {body, conn} = read_json(conn)
        assert body["questions"]["x"]["weight"] == 2
        respond(conn, 200, ok_body(%{"x" => raw_answer}))
      end)

      response =
        TypeSafe.system_one!(client(), "text", %{x: %{"type" => "future", "weight" => 2}})

      assert response.answers.x == raw_answer
    end

    test "a missing or malformed answer is an invalid response naming the field" do
      Req.Test.expect(__MODULE__, fn conn ->
        respond(conn, 200, ok_body(Map.delete(answers(), "urgency")))
      end)

      assert {:error, %Error{reason: :invalid_response} = error} =
               TypeSafe.system_one(client(), "text", questions())

      assert error.message =~ "answers.urgency"

      Req.Test.expect(__MODULE__, fn conn ->
        respond(conn, 200, ok_body(put_in(answers(), ["team", "confidence"], "high")))
      end)

      assert {:error, %Error{message: message}} =
               TypeSafe.system_one(client(), "text", questions())

      assert message =~ "answers.team.confidence"
    end
  end

  describe "errors" do
    test "an HTTP error carries its reason, the server's message and the request id" do
      Req.Test.expect(__MODULE__, fn conn ->
        respond(conn, 401, %{"error" => "Invalid API key"}, [{"x-typesafe-request-id", "req_9"}])
      end)

      assert {:error, %Error{reason: :authentication, status: 401} = error} =
               TypeSafe.system_one(client(), "text", questions())

      assert Exception.message(error) == "401 Invalid API key (request_id=req_9)"
    end

    test "validation errors are summarized by field" do
      Req.Test.expect(__MODULE__, fn conn ->
        respond(conn, 422, %{
          "detail" => [
            %{"loc" => ["body", "questions", "team", "criteria"], "msg" => "Field required"}
          ]
        })
      end)

      assert {:error,
              %Error{
                reason: :unprocessable_entity,
                message: "questions.team.criteria: Field required"
              }} =
               TypeSafe.system_one(client(), "text", questions())
    end

    test "system_one!/4 raises the error" do
      Req.Test.expect(__MODULE__, &respond(&1, 400, %{"message" => "bad"}))

      assert_raise Error, "400 bad", fn -> TypeSafe.system_one!(client(), "text", questions()) end
    end
  end

  describe "retries" do
    test "a 529 is retried, and the retry says which attempt it is" do
      test = self()

      Req.Test.expect(__MODULE__, &respond(&1, 529, %{"error" => "Overloaded"}))

      Req.Test.expect(__MODULE__, fn conn ->
        send(test, {:retry_count, Plug.Conn.get_req_header(conn, "x-typesafe-retry-count")})
        respond(conn, 200, ok_body())
      end)

      assert {:ok, _response} = TypeSafe.system_one(client(), "text", questions())
      assert_received {:retry_count, ["1"]}
    end

    test "gives up after max_retries, keeping the server's wait" do
      Req.Test.expect(
        __MODULE__,
        3,
        &respond(&1, 429, %{"error" => "Slow down"}, [{"retry-after-ms", "0"}])
      )

      assert {:error, %Error{reason: :rate_limited, retry_after_ms: 0}} =
               TypeSafe.system_one(client(), "text", questions())
    end

    test "a wait longer than the budget is not attempted" do
      Req.Test.expect(__MODULE__, &respond(&1, 429, %{}, [{"retry-after", "60"}]))

      assert {:error, %Error{reason: :rate_limited, retry_after_ms: 60_000}} =
               TypeSafe.system_one(client(), "text", questions())
    end

    test "client errors are not retried, and retry: false turns retrying off" do
      Req.Test.expect(__MODULE__, &respond(&1, 400, %{}))

      assert {:error, %Error{reason: :bad_request}} =
               TypeSafe.system_one(client(), "text", questions())

      Req.Test.expect(__MODULE__, &respond(&1, 503, %{}))

      assert {:error, %Error{reason: :server_error}} =
               TypeSafe.system_one(client(), "text", questions(), retry: false)
    end

    test "timeouts are retried, then reported" do
      Req.Test.expect(__MODULE__, 3, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %Error{reason: :timeout, status: nil}} =
               TypeSafe.system_one(client(), "text", questions())
    end

    test "a refused connection is a connection error" do
      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{reason: :connection}} =
               TypeSafe.system_one(client(retry: false), "text", questions())
    end
  end

  describe "models/1" do
    test "lists the model names with parsed release dates" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/models"

        respond(conn, 200, %{
          "models" => [
            %{
              "name" => "jev-latest",
              "description" => "Latest",
              "release_date" => "2026-09-10T18:38:01Z"
            }
          ]
        })
      end)

      assert [%TypeSafe.Model{name: "jev-latest", release_date: %DateTime{year: 2026}}] =
               TypeSafe.models!(client())
    end
  end

  describe "question builders" do
    test "reject malformed questions" do
      assert_raise ArgumentError, ~r/instructions/, fn -> TypeSafe.noul("  ") end
      assert_raise ArgumentError, ~r/true or false/, fn -> TypeSafe.noul("Is it?", maybe: "x") end
      assert_raise ArgumentError, ~r/at least one option/, fn -> TypeSafe.choice("Which?", []) end
      assert_raise ArgumentError, ~r/unique/, fn -> TypeSafe.choice("Which?", [:a, "a"]) end

      assert_raise ArgumentError, ~r/atoms or non-empty strings/, fn ->
        TypeSafe.choice("Which?", [nil])
      end

      assert_raise ArgumentError, ~r/at least two levels/, fn ->
        TypeSafe.score("How?", ["only"])
      end
    end

    test "reject a questions map that is empty or holds something else" do
      assert_raise ArgumentError, ~r/non-empty map/, fn ->
        TypeSafe.system_one(client(), "text", %{})
      end

      assert_raise ArgumentError, ~r/must be built/, fn ->
        TypeSafe.system_one(client(), "text", %{q: "Is it?"})
      end

      assert_raise ArgumentError, ~r/unique/, fn ->
        TypeSafe.system_one(client(), "text", %{
          :q => TypeSafe.noul("A?"),
          "q" => TypeSafe.noul("B?")
        })
      end
    end
  end

  describe "answer helpers" do
    test "rank, normalize and threshold" do
      choice = %ChoiceAnswer{
        choice: :b,
        probabilities: %{a: 0.2, b: 0.7, c: 0.1},
        confidence: 0.5
      }

      assert ChoiceAnswer.ranked(choice) == [b: 0.7, a: 0.2, c: 0.1]

      score = %ScoreAnswer{
        score: 2.25,
        legend: %{0 => "a", 1 => "b", 2 => "c", 3 => "d"},
        probabilities: %{0 => 0.0, 1 => 0.25, 2 => 0.25, 3 => 0.5},
        confidence: 0.4
      }

      assert ScoreAnswer.normalized(score) == 0.75
      assert ScoreAnswer.level(score) == 3

      assert NoulAnswer.yes?(%NoulAnswer{noul: 0.6})
      refute NoulAnswer.yes?(%NoulAnswer{noul: 0.6}, 0.8)
    end
  end

  test "inspecting a client never shows the key" do
    refute inspect(client()) =~ "test-key"
  end

  test "each request emits telemetry" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:typesafe, :request, :stop]])

    Req.Test.expect(
      __MODULE__,
      &respond(&1, 200, ok_body(), [{"x-typesafe-request-id", "req_t"}])
    )

    TypeSafe.system_one!(client(), "text", questions())

    assert_received {[:typesafe, :request, :stop], ^ref, %{duration: _},
                     %{
                       result: :ok,
                       request_id: "req_t",
                       path: "/v1/systemone",
                       model: "jev-latest"
                     }}
  end
end

defmodule TypeSafe.EnvTest do
  # Environment variables are global, so these run alone.
  use ExUnit.Case, async: false

  setup do
    names = ~w(TYPESAFE_API_KEY TYPESAFE_BASE_URL TYPESAFE_DEFAULT_MODEL)
    saved = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "without a key, calls fail fast and make no request" do
    client = TypeSafe.new(req_options: [plug: fn _conn -> flunk("no request should be made") end])

    refute TypeSafe.configured?(client)

    assert {:error, %TypeSafe.Error{reason: :no_api_key}} =
             TypeSafe.system_one(client, "text", %{q: TypeSafe.noul("Is it?")})
  end

  test "reads the key, base URL and model from the environment, options first" do
    System.put_env("TYPESAFE_API_KEY", " env-key ")
    System.put_env("TYPESAFE_BASE_URL", "https://example.test/")
    System.put_env("TYPESAFE_DEFAULT_MODEL", "jev-1.13.0")

    client = TypeSafe.new()
    assert client.api_key == "env-key"
    assert client.base_url == "https://example.test"
    assert client.model == "jev-1.13.0"

    assert TypeSafe.new(model: "jev-preview").model == "jev-preview"
  end
end
