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

  test "a bad key is an authentication error" do
    assert {:error, %TypeSafe.Error{reason: :authentication, status: 401}} =
             TypeSafe.system_one(TypeSafe.new(api_key: "not-a-key"), "text", %{
               q: TypeSafe.noul("Is it?")
             })
  end
end
