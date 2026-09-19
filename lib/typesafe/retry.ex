defmodule TypeSafe.Retry do
  @moduledoc """
  When and how long to wait before retrying. The defaults match TypeSafe's official SDKs:

    * `:max_retries` (2) - retries after the first attempt; `0` disables retrying
    * `:backoff_initial` (500) and `:backoff_max` (5_000) - milliseconds; the delay doubles
      each attempt up to the maximum
    * `:jitter` (0.25) - fraction of each delay randomly taken off, between 0 and 1
    * `:statuses` - HTTP statuses that are retried: 408, 429 and every 5xx, which
      includes TypeSafe's 529 (overloaded)
    * `:respect_retry_after` (true) - wait as long as `retry-after-ms` or `retry-after` says
    * `:retry_connection_errors` (true) - retry timeouts and failed connections
    * `:budget` (30_000) - total milliseconds per call, including waits; a retry whose wait
      would pass it is not attempted. `nil` for no limit.

  Pass `retry: [max_retries: 5]` to `TypeSafe.new/1` or to a single call, or `retry: false`.
  """

  defstruct max_retries: 2,
            backoff_initial: 500,
            backoff_max: 5_000,
            jitter: 0.25,
            statuses: [408, 429 | Enum.to_list(500..599)],
            respect_retry_after: true,
            retry_connection_errors: true,
            budget: 30_000

  @type t :: %__MODULE__{
          max_retries: non_neg_integer(),
          backoff_initial: non_neg_integer(),
          backoff_max: non_neg_integer(),
          jitter: float(),
          statuses: [pos_integer()],
          respect_retry_after: boolean(),
          retry_connection_errors: boolean(),
          budget: pos_integer() | nil
        }

  @doc false
  def new(false), do: %__MODULE__{max_retries: 0}
  def new(%__MODULE__{} = policy), do: policy

  def new(opts) when is_list(opts) do
    policy = struct!(__MODULE__, opts)

    unless is_integer(policy.max_retries) and policy.max_retries >= 0,
      do: raise(ArgumentError, ":max_retries must be a non-negative integer")

    unless is_number(policy.jitter) and policy.jitter >= 0 and policy.jitter <= 1,
      do: raise(ArgumentError, ":jitter must be between 0 and 1")

    for key <- [:backoff_initial, :backoff_max],
        not (is_integer(Map.fetch!(policy, key)) and Map.fetch!(policy, key) >= 0),
        do: raise(ArgumentError, "#{inspect(key)} must be a non-negative integer of milliseconds")

    policy
  end

  @doc false
  # Options for Req. The decision function sees our own attempt counter and the
  # call's deadline, both kept in the request's private map.
  def req_options(%__MODULE__{max_retries: 0}), do: [retry: false]

  def req_options(%__MODULE__{} = policy) do
    [retry: &decide(policy, &1, &2), max_retries: policy.max_retries]
  end

  @doc false
  def decide(policy, request, response_or_exception) do
    if retryable?(policy, response_or_exception) do
      attempt = Req.Request.get_private(request, :typesafe_attempt, 1)
      delay = delay(policy, response_or_exception, attempt)
      deadline = Req.Request.get_private(request, :typesafe_deadline)

      if deadline && System.monotonic_time(:millisecond) + delay >= deadline,
        do: false,
        else: {:delay, delay}
    else
      false
    end
  end

  defp retryable?(policy, %Req.Response{status: status}), do: status in policy.statuses
  defp retryable?(policy, %{__exception__: true}), do: policy.retry_connection_errors

  defp delay(policy, response_or_exception, attempt) do
    server_delay =
      with true <- policy.respect_retry_after,
           %Req.Response{} = response <- response_or_exception do
        retry_after_ms(response)
      else
        _ -> nil
      end

    server_delay || backoff(policy, attempt)
  end

  defp backoff(%__MODULE__{backoff_initial: 0}, _attempt), do: 0
  defp backoff(%__MODULE__{backoff_max: 0}, _attempt), do: 0

  defp backoff(policy, attempt) do
    exponential = min(policy.backoff_initial * Integer.pow(2, attempt - 1), policy.backoff_max)
    round(exponential * (1 - :rand.uniform() * policy.jitter))
  end

  @doc false
  # `retry-after-ms` first, then `retry-after` as seconds or an HTTP date.
  def retry_after_ms(%Req.Response{} = response) do
    with nil <- header_number(response, "retry-after-ms", 1),
         nil <- header_number(response, "retry-after", 1000) do
      http_date_delay(response)
    end
  end

  defp header_number(response, name, multiplier) do
    with [raw | _] <- Req.Response.get_header(response, name),
         {value, ""} when value >= 0 <- Float.parse(String.trim(raw)) do
      round(value * multiplier)
    else
      _ -> nil
    end
  end

  defp http_date_delay(response) do
    Req.Response.get_retry_after(response)
  rescue
    _malformed -> nil
  end
end
