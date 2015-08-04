defmodule Phoenix.Transports.LongPoll do
  @moduledoc """
  Socket transport for long poll clients.

  ## Configuration

  The long poll is configurable in your socket:

      transport :longpoll, Phoenix.Transports.LongPoll,
        window_ms: 10_000,
        pubsub_timeout_ms: 1000,
        log: false,
        check_origin: true,
        crypto: [max_age: 1209600]

    * `:window_ms` - how long the client can wait for new messages
      in its poll request

    * `:pubsub_timeout_ms` - how long a request can wait for the
      pubsub layer to respond

    * `:crypto` - options for verifying and signing the token, accepted
      by `Phoenix.Token`. By default tokens are valid for 2 weeks

    * `:log` - if the transport layer itself should log and, if so, the level

    * `:check_origin` - if we should check the origin of requests when the
      origin header is present. It defaults to true and, in such cases,
      it will check against the host value in `YourApp.Endpoint.config(:url)[:host]`.
      It may be set to `false` (not recommended) or to a list of explicitly
      allowed origins
  """

  ## Transport callbacks

  @behaviour Phoenix.Socket.Transport

  def default_config() do
    [window_ms: 10_000,
     pubsub_timeout_ms: 1000,
     serializer: Phoenix.Transports.LongPollSerializer,
     log: false,
     check_origin: true,
     crypto: [max_age: 1209600]]
  end

  def handlers() do
    %{cowboy: Plug.Adapters.Cowboy.Handler}
  end

  ## Plug callbacks

  @behaviour Plug
  @behaviour Phoenix.Socket.Transport
  @plug_parsers Plug.Parsers.init(parsers: [:json], json_decoder: Poison)

  import Plug.Conn

  alias Phoenix.Socket.Message
  alias Phoenix.Transports.LongPoll
  alias Phoenix.Socket.Transport

  @doc false
  def init(opts) do
    opts
  end

  @doc false
  def call(conn, {endpoint, handler, transport}) do
    {_, opts} = handler.__transport__(transport)

    conn
    |> fetch_query_params
    |> Plug.Conn.fetch_query_params
    |> Transport.transport_log(opts[:log])
    |> Transport.force_ssl(handler, endpoint)
    |> Transport.check_origin(endpoint, opts[:check_origin], &status_json(&1, %{}))
    |> dispatch(endpoint, handler, transport, opts)
  end

  defp dispatch(%{halted: true} = conn, _, _, _, _) do
    conn
  end

  # Responds to pre-flight CORS requests with Allow-Origin-* headers.
  # We allow cross-origin requests as we always validate the Origin header.
  defp dispatch(%{method: "OPTIONS"} = conn, _, _, _, _) do
    headers = get_req_header(conn, "access-control-request-headers") |> Enum.join(", ")

    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-headers", headers)
    |> put_resp_header("access-control-allow-methods", "get, post, options")
    |> put_resp_header("access-control-max-age", "3600")
    |> send_resp(:ok, "")
  end

  # Starts a new session or listen to a message if one already exists.
  defp dispatch(%{method: "GET"} = conn, endpoint, handler, transport, opts) do
    case resume_session(conn.params, endpoint, opts) do
      {:ok, priv_topic} ->
        listen(conn, priv_topic, endpoint, opts)
      :error ->
        new_session(conn, endpoint, handler, transport, opts)
    end
  end

  # Publish the message encoded as a JSON body.
  defp dispatch(%{method: "POST"} = conn, endpoint, _, _, opts) do
    case resume_session(conn.params, endpoint, opts) do
      {:ok, priv_topic} ->
        conn |> Plug.Parsers.call(@plug_parsers) |> publish(priv_topic, endpoint, opts)
      :error ->
        conn |> put_status(:gone) |> status_json(%{})
    end
  end

  # All other requests should fail.
  defp dispatch(conn, _, _, _, _) do
    conn |> send_resp(:bad_request, "")
  end

  ## Connection helpers

  defp new_session(conn, endpoint, handler, transport, opts) do
    serializer = opts[:serializer]

    case Transport.connect(endpoint, handler, transport, __MODULE__, serializer, conn.params) do
      {:ok, socket} ->
        {_, token, _} = start_session(endpoint, socket, opts)
        conn |> put_status(:gone) |> status_json(%{token: token})

      :error ->
        conn |> put_status(:forbidden) |> status_json(%{})
    end
  end

  defp listen(conn, priv_topic, endpoint, opts) do
    ref = :erlang.make_ref()
    :ok = broadcast_from(endpoint, priv_topic, {:flush, ref})

    receive do
      {:messages, msgs, ^ref} ->
        :ok = ack(endpoint, priv_topic, msgs, opts)
        status_json(conn, %{messages: msgs, token: conn.params["token"]})
    after
      opts[:window_ms] ->
        :ok = ack(endpoint, priv_topic, [], opts)
        conn |> put_status(:no_content) |> status_json(%{token: conn.params["token"]})
    end
  end

  defp publish(conn, priv_topic, endpoint, opts) do
    msg = Message.from_map!(conn.body_params)

    case transport_dispatch(endpoint, priv_topic, msg, opts) do
      :ok               -> conn |> put_status(:ok) |> status_json(%{})
      {:error, _reason} -> conn |> put_status(:unauthorized) |> status_json(%{})
    end
  end

  ## Endpoint helpers

  # Starts the `Phoenix.LongPoll.Server` and retunrs the encrypted token.
  @doc false
  def start_session(endpoint, socket, opts) do
    priv_topic =
      "phx:lp:"
      <> Base.encode64(:crypto.strong_rand_bytes(16))
      <> (:os.timestamp() |> Tuple.to_list |> Enum.join(""))

    child = [socket, opts[:window_ms], priv_topic]
    {:ok, server_pid} = Supervisor.start_child(LongPoll.Supervisor, child)
    {priv_topic, sign_token(endpoint, priv_topic, opts), server_pid}
  end

  # Retrieves the serialized `Phoenix.LongPoll.Server` pid
  # by publishing a message in the encrypted private topic.
  @doc false
  def resume_session(%{"token" => token}, endpoint, opts) do
    case verify_token(endpoint, token, opts) do
      {:ok, priv_topic} ->
        ref = :erlang.make_ref()
        :ok = subscribe(endpoint, priv_topic)
        :ok = broadcast_from(endpoint, priv_topic, {:subscribe, ref})

        receive do
          {:ok, :subscribe, ^ref} -> {:ok, priv_topic}
        after
          opts[:pubsub_timeout_ms]  -> :error
        end

      {:error, _} ->
        :error
    end
  end
  def resume_session(_params, _endpoint, _opts), do: :error

  # Ack's a list of message refs back to the `Phoenix.LongPoll.Server`.
  # To be called after buffered messages have been relayed to the client.
  defp ack(endpoint, priv_topic, msgs, opts) do
    ref = :erlang.make_ref()
    :ok = broadcast_from(endpoint, priv_topic, {:ack, length(msgs), ref})
    receive do
      {:ok, :ack, ^ref} -> :ok
    after
      opts[:pubsub_timeout_ms] -> :error
    end
  end

  # Dispatches a message to the pubsub system.
  defp transport_dispatch(endpoint, priv_topic, msg, opts) do
    ref = :erlang.make_ref()
    :ok = broadcast_from(endpoint, priv_topic, {:dispatch, msg, ref})

    receive do
      {:ok, :dispatch, ^ref}            -> :ok
      {:error, :dispatch, reason, ^ref} -> {:error, reason}
    after
      opts[:pubsub_timeout_ms] -> {:error, :timeout}
    end
  end

  defp subscribe(endpoint, priv_topic) do
    Phoenix.PubSub.subscribe(endpoint.__pubsub_server__, self, priv_topic, link: true)
  end

  defp broadcast_from(endpoint, priv_topic, msg) do
    Phoenix.PubSub.broadcast_from(endpoint.__pubsub_server__, self, priv_topic, msg)
  end

  defp sign_token(endpoint, priv_topic, opts) do
    Phoenix.Token.sign(endpoint, Atom.to_string(endpoint.__pubsub_server__), priv_topic, opts[:crypto])
  end

  defp verify_token(endpoint, signed, opts) do
    Phoenix.Token.verify(endpoint, Atom.to_string(endpoint.__pubsub_server__), signed, opts[:crypto])
  end

  defp status_json(conn, data) do
    status = Plug.Conn.Status.code(conn.status || 200)
    data   = Map.put(data, :status, status)
    conn
    |> put_status(200)
    |> Phoenix.Controller.json(data)
  end
end