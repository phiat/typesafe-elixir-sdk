defmodule TypeSafe.Client do
  @moduledoc """
  Connection settings, built with `TypeSafe.new/1`. The API key is kept out of
  `inspect/1` output.
  """

  alias TypeSafe.{Error, Retry}

  @version Mix.Project.config()[:version]
  @default_base_url "https://api.typesafe.ai"
  @default_model "jev-latest"
  @default_timeout 10_000

  @derive {Inspect, except: [:api_key]}
  defstruct api_key: nil,
            base_url: @default_base_url,
            model: @default_model,
            timeout: @default_timeout,
            retry: %Retry{},
            headers: [],
            req_options: []

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          base_url: String.t(),
          model: String.t(),
          timeout: pos_integer(),
          retry: Retry.t(),
          headers: [{String.t(), String.t()}],
          req_options: keyword()
        }

  @doc false
  def new(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        :base_url,
        :model,
        :timeout,
        :retry,
        :headers,
        :req_options
      ])

    %__MODULE__{
      api_key: opts[:api_key] || env("TYPESAFE_API_KEY"),
      base_url:
        String.trim_trailing(
          opts[:base_url] || env("TYPESAFE_BASE_URL") || @default_base_url,
          "/"
        ),
      model: opts[:model] || env("TYPESAFE_DEFAULT_MODEL") || @default_model,
      timeout: check_timeout!(Keyword.get(opts, :timeout, @default_timeout)),
      retry: Retry.new(Keyword.get(opts, :retry, [])),
      headers: Keyword.get(opts, :headers, []),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @doc false
  # Returns {:ok, decoded_body, request_id} for a 2xx with a JSON object body, and
  # {:error, %TypeSafe.Error{}} for everything else.
  def request(%__MODULE__{api_key: nil}, _method, _path, _body, _opts) do
    {:error,
     %Error{
       reason: :no_api_key,
       message: "no API key: pass :api_key to TypeSafe.new/1 or set TYPESAFE_API_KEY"
     }}
  end

  def request(%__MODULE__{} = client, method, path, body, opts) do
    metadata = %{method: method, path: path, model: body && body["model"]}

    :telemetry.span([:typesafe, :request], metadata, fn ->
      result = client |> build(method, path, body, opts) |> Req.request() |> handle()
      {result, Map.merge(metadata, stop_metadata(result))}
    end)
  end

  defp build(client, method, path, body, opts) do
    retry = if Keyword.has_key?(opts, :retry), do: Retry.new(opts[:retry]), else: client.retry
    timeout = check_timeout!(Keyword.get(opts, :timeout, client.timeout))
    deadline = retry.budget && System.monotonic_time(:millisecond) + retry.budget

    headers =
      merge_headers([
        [
          {"accept", "application/json"},
          {"user-agent", "typesafe_ex/#{@version}"},
          {"x-typesafe-sdk", "typesafe_ex/#{@version}"},
          {"x-typesafe-runtime", runtime()}
        ],
        client.headers,
        Keyword.get(opts, :headers, [])
      ])

    [
      method: method,
      base_url: client.base_url,
      url: path,
      auth: {:bearer, client.api_key},
      headers: headers,
      receive_timeout: timeout
    ]
    |> Kernel.++(if body, do: [json: body], else: [])
    |> Kernel.++(Retry.req_options(retry))
    |> Req.new()
    |> Req.Request.put_private(:typesafe_deadline, deadline)
    |> Req.Request.append_request_steps(typesafe_attempt: &count_attempt/1)
    |> Req.merge(client.req_options)
  end

  # Runs before every attempt, retries included: Req re-runs request steps.
  defp count_attempt(request) do
    attempt = Req.Request.get_private(request, :typesafe_attempt, 0) + 1
    request = Req.Request.put_private(request, :typesafe_attempt, attempt)

    if attempt > 1,
      do:
        Req.Request.put_header(request, "x-typesafe-retry-count", Integer.to_string(attempt - 1)),
      else: request
  end

  defp handle({:ok, %Req.Response{status: status, body: %{} = body} = response})
       when status in 200..299,
       do: {:ok, body, Error.request_id(response)}

  defp handle({:ok, %Req.Response{status: status} = response}) when status in 200..299 do
    {:error,
     %Error{
       reason: :invalid_response,
       status: status,
       message: "expected a JSON object body",
       body: response.body,
       request_id: Error.request_id(response)
     }}
  end

  defp handle({:ok, %Req.Response{} = response}), do: {:error, Error.from_response(response)}
  defp handle({:error, exception}), do: {:error, Error.from_exception(exception)}

  defp stop_metadata({:ok, _body, request_id}), do: %{result: :ok, request_id: request_id}

  defp stop_metadata({:error, %Error{} = error}),
    do: %{
      result: :error,
      reason: error.reason,
      status: error.status,
      request_id: error.request_id
    }

  defp merge_headers(lists) do
    lists
    |> Enum.concat()
    |> Enum.reduce(%{}, fn {name, value}, acc ->
      Map.put(acc, String.downcase(to_string(name)), value)
    end)
    |> Map.to_list()
  end

  defp runtime do
    "elixir/#{System.version()} (otp #{System.otp_release()}; #{:erlang.system_info(:system_architecture)})"
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  defp check_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp check_timeout!(timeout),
    do:
      raise(
        ArgumentError,
        ":timeout must be a positive integer of milliseconds, got: #{inspect(timeout)}"
      )
end
