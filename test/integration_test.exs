defmodule TypeSafe.IntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  setup do
    client = TypeSafe.new()

    if !TypeSafe.configured?(client),
      do: flunk("set TYPESAFE_API_KEY to run the integration tests")

    %{client: client}
  end

  test "lists models", %{client: client} do
    assert "jev-latest" in Enum.map(TypeSafe.models!(client), & &1.name)
  end

  test "answers all three question types in one call", %{client: client} do
    response =
      TypeSafe.system_one!(
        client,
        %{ticket: "I was charged twice for my order. Please refund one."},
        %{
          billing: TypeSafe.noul("Is this ticket about billing?"),
          tone: TypeSafe.choice("What is the customer's tone?", [:calm, :frustrated, :furious]),
          urgency:
            TypeSafe.score("How urgent is this ticket?", [
              "Can wait: nothing is blocked",
              "Soon: a problem with a workaround",
              "Today: something important is broken"
            ])
        }
      )

    assert response.model =~ ~r/^jev-/
    assert is_binary(response.request_id)
    assert response.usage.input_tokens > 0

    assert TypeSafe.NoulAnswer.yes?(response.answers.billing)
    assert response.answers.tone.choice in [:calm, :frustrated, :furious]
    assert_in_delta Enum.sum(Map.values(response.answers.tone.probabilities)), 1.0, 0.01
    assert response.answers.urgency.score >= 0 and response.answers.urgency.score <= 2
    assert Map.keys(response.answers.urgency.legend) == [0, 1, 2]
  end

  test "locates a rectangle in a PNG", %{client: client} do
    photo = TypeSafe.Image.from_file!(fixture("red-rectangle.png"))

    response =
      TypeSafe.system_one!(
        client,
        %{photo: photo},
        %{
          present: TypeSafe.noul("Is there a red rectangle in `photo`?"),
          rect: TypeSafe.box("The red rectangle in `photo`")
        },
        # A Box question needs jev-1.14.0 (or jev-preview); jev-latest was 1.13.
        model: "jev-1.14.0",
        images: [photo]
      )

    assert response.model == "jev-1.14.0"
    assert TypeSafe.NoulAnswer.yes?(response.answers.present)

    %TypeSafe.BoxAnswer{} = rect = response.answers.rect
    assert rect.left < rect.right and rect.top < rect.bottom

    # The rectangle is at left 0.5, right 0.9, top 0.2, bottom 0.5.
    for {edge, want} <- [left: 0.5, right: 0.9, top: 0.2, bottom: 0.5] do
      assert_in_delta Map.fetch!(rect, edge), want, 0.15
    end

    assert rect.confidence > 0.5
  end

  test "reads a JPEG on the default model", %{client: client} do
    photo = TypeSafe.Image.from_file!(fixture("red-rectangle.jpg"))

    response =
      TypeSafe.system_one!(
        client,
        %{photo: photo},
        %{red: TypeSafe.noul("Does `photo` contain a red shape?")},
        images: [photo]
      )

    assert TypeSafe.NoulAnswer.yes?(response.answers.red)
  end

  test "accepts the long-context header", %{client: client} do
    response =
      TypeSafe.system_one!(client, "Hello there!", %{hello: TypeSafe.noul("Is this a greeting?")},
        long_context: true
      )

    assert TypeSafe.NoulAnswer.yes?(response.answers.hello)
  end

  test "a bad key is an authentication error" do
    assert {:error, %TypeSafe.Error{reason: :authentication, status: 401}} =
             TypeSafe.system_one(TypeSafe.new(api_key: "not-a-key"), "text", %{
               q: TypeSafe.noul("Is it?")
             })
  end

  defp fixture(name), do: Path.join([__DIR__, "fixtures", name])
end
