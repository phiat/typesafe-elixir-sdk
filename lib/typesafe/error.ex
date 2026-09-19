defmodule TypeSafe.Error do
  @moduledoc """
  Why a call failed. Returned as `{:error, %TypeSafe.Error{}}`, raised by the bang
  functions.

  `reason` is one of:

    * `:no_api_key` - no key was given and `TYPESAFE_API_KEY` is unset; no request was made
    * `:bad_request` (400), `:authentication` (401), `:permission_denied` (403),
      `:not_found` (404), `:unprocessable_entity` (422), `:rate_limited` (429),
      `:overloaded` (529), `:server_error` (other 5xx), `:http_error` (anything else)
    * `:timeout`, `:connection` - no HTTP response
    * `:invalid_response` - a 2xx whose body is missing a required field; `message`
      names the field

  `request_id` is the `x-typesafe-request-id` header, when there was a response.
  """

  defexception [:reason, :status, :message, :body, :request_id, :retry_after_ms]

  @type reason ::
          :no_api_key
          | :bad_request
          | :authentication
          | :permission_denied
          | :not_found
          | :unprocessable_entity
          | :rate_limited
          | :overloaded
          | :server_error
          | :http_error
          | :timeout
          | :connection
          | :invalid_response

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          message: String.t(),
          body: term(),
          request_id: String.t() | nil,
          retry_after_ms: non_neg_integer() | nil
        }

  @max_body_in_message 200

  @impl true
  def message(%__MODULE__{} = error) do
    prefix = if error.status, do: "#{error.status} ", else: ""
    suffix = if error.request_id, do: " (request_id=#{error.request_id})", else: ""
    prefix <> error.message <> suffix
  end

  @doc false
  def reason_for_status(400), do: :bad_request
  def reason_for_status(401), do: :authentication
  def reason_for_status(403), do: :permission_denied
  def reason_for_status(404), do: :not_found
  def reason_for_status(422), do: :unprocessable_entity
  def reason_for_status(429), do: :rate_limited
  def reason_for_status(529), do: :overloaded
  def reason_for_status(status) when status >= 500, do: :server_error
  def reason_for_status(_status), do: :http_error

  @doc false
  def from_response(%Req.Response{status: status, body: body} = response) do
    %__MODULE__{
      reason: reason_for_status(status),
      status: status,
      message: extract_message(body) || fallback_message(body),
      body: body,
      request_id: request_id(response),
      retry_after_ms: TypeSafe.Retry.retry_after_ms(response)
    }
  end

  @doc false
  def from_exception(%Req.TransportError{reason: :timeout} = exception),
    do: %__MODULE__{reason: :timeout, message: Exception.message(exception)}

  def from_exception(exception),
    do: %__MODULE__{reason: :connection, message: Exception.message(exception)}

  @doc false
  def request_id(%Req.Response{} = response) do
    case Req.Response.get_header(response, "x-typesafe-request-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  # The same message shapes the official SDKs read: a string error, an error or
  # detail object with a message, or a validation list of {loc, msg}.
  defp extract_message(body) when is_binary(body) and body != "", do: body

  defp extract_message(%{} = body) do
    case body do
      %{"error" => error} when is_binary(error) -> error
      %{"error" => %{"message" => message}} when is_binary(message) -> message
      %{"message" => message} when is_binary(message) -> message
      %{"detail" => detail} when is_binary(detail) -> detail
      %{"detail" => %{"message" => message}} when is_binary(message) -> message
      %{"detail" => detail} when is_list(detail) -> validation_message(detail)
      _other -> nil
    end
  end

  defp extract_message(_body), do: nil

  defp validation_message(entries) do
    parts =
      for %{"msg" => msg} = entry <- entries, is_binary(msg) do
        path =
          entry
          |> Map.get("loc", [])
          |> List.wrap()
          |> Enum.reject(&(&1 == "body"))
          |> Enum.join(".")

        if path == "", do: msg, else: "#{path}: #{msg}"
      end

    if parts == [], do: nil, else: Enum.join(parts, "; ")
  end

  defp fallback_message(body) when body in [nil, ""], do: "(no body)"

  defp fallback_message(body) do
    raw = if is_binary(body), do: body, else: Jason.encode!(body)

    if String.length(raw) > @max_body_in_message,
      do: String.slice(raw, 0, @max_body_in_message) <> "…",
      else: raw
  end
end
