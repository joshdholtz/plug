defmodule Plug.CSRFProtection do
  @moduledoc """
  Plug to protect from cross-site request forgery.

  For this plug to work, it expects a session to have been
  previously fetched. It will then compare the plug stored
  in the session with the one sent by the request, when they
  do not match, an `Plug.CSRFProtection.InvalidCSRFTokenError`
  error is raised.

  The token may be sent by the request either via the params
  with key "_csrf_token" or a header with name "x-csrf-token".

  GET requests are not protected, as they should not have any
  side-effect or change your application state. JavaScript
  requests are an exception: by using a script tag, external
  websites can embed server-side generated JavaScript, which
  can leak information. For this reason, this plug also forbids
  any GET JavaScript request that is not XHR (or AJAX).

  ## Token generation

  This plug won't generate tokens automatically. Instead,
  tokens will be generated only when required by calling
  `Plug.CSRFProtection.get_csrf_token/0`. The token is then
  stored in the process dictionary to be set in the request.

  One may wonder: why the process dictionary?

  The CSRF token is usually generated inside forms which may
  be isolated from the connection. Storing them in process
  dictionary allow them to be generated as a side-effect,
  becoming one of those rare situations where using the process
  dictionary is useful.

  ## Disabling

  You may disable this plug by doing
  `Plug.Conn.put_private(:plug_skip_csrf_protection, true)`.

  ## Examples

      plug Plug.Session, ...
      plug :fetch_session
      plug Plug.CSRFProtection

  """

  import Plug.Conn
  @unprotected_methods ~w(HEAD GET OPTIONS)

  defmodule InvalidCSRFTokenError do
    @moduledoc "Error raised when CSRF token is invalid."
    message = "invalid CSRF (Cross Site Forgery Protection) token. Make sure that all " <>
              "your non-HEAD and non-GET requests include the '_csrf_token' as part of form " <>
              "params or as a value in your request's headers with the key 'x-csrf-token'"

    defexception message: message, plug_status: 403
  end

  defmodule InvalidCrossOriginRequestError do
    @moduledoc "Error raised when non-XHR requests are used for Javascript responses."
    message = "security warning: an embedded <script> tag on another site requested " <>
              "protected JavaScript. If you know what you're doing, you may disable " <>
              "forgery protection for this route"

    defexception message: message, plug_status: 403
  end

  ## API

  @doc """
  Gets the CSRF token.

  Generates a token and stores it in the process
  dictionary if one does not exists.
  """
  def get_csrf_token do
    Process.get(:plug_csrf_token) || (
      token = generate_token()
      Process.put(:plug_csrf_token, token)
      token
    )
  end

  @doc """
  Deletes the CSRF token from the process dictionary.

  This will force the token to be deleted once the response is sent.
  """
  def delete_csrf_token do
    Process.delete(:plug_csrf_token)
  end

  ## Plug

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    csrf_token = get_session(conn, "_csrf_token")
    Process.put(:plug_csrf_token, csrf_token)

    if not verified_request?(conn, csrf_token) do
      raise InvalidCSRFTokenError
    end

    register_before_send(conn, &ensure_same_origin_and_csrf_token(&1, csrf_token))
  end

  ## Verification

  defp verified_request?(conn, csrf_token) do
    conn.method in @unprotected_methods
      || valid_csrf_token?(csrf_token, conn.params["_csrf_token"])
      || valid_csrf_token?(csrf_token, get_req_header(conn, "x-csrf-token") |> Enum.at(0))
      || plug_skip_csrf_protection?(conn)
  end

  defp valid_csrf_token?(csrf_token, user_token) do
    csrf_token && user_token &&
      Plug.Crypto.secure_compare(csrf_token, user_token)
  end

  ## Before send

  def ensure_same_origin_and_csrf_token(conn, csrf_token) do
    if cross_origin_js?(conn) do
      raise InvalidCrossOriginRequestError
    end

    ensure_csrf_token(conn, csrf_token)
  end

  defp cross_origin_js?(conn) do
    conn.method == "GET" and not xhr?(conn) and not plug_skip_csrf_protection?(conn) and
      Enum.any?(get_resp_header(conn, "content-type"),
                &String.starts_with?(&1, ["text/javascript", "application/javascript"]))
  end

  defp xhr?(conn) do
    "XMLHttpRequest" in get_req_header(conn, "x-requested-with")
  end

  defp ensure_csrf_token(conn, csrf_token) do
    current = Process.delete(:plug_csrf_token)

    if current == csrf_token do
      conn
    else
      put_session(conn, "_csrf_token", current)
    end
  end

  ## Helpers

  defp plug_skip_csrf_protection?(%{private: %{plug_skip_csrf_protection: true}}), do: true
  defp plug_skip_csrf_protection?(_), do: false

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.encode64
  end
end
