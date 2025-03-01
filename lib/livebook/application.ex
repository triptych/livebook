defmodule Livebook.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    ensure_directories!()
    set_local_filesystem!()
    ensure_distribution!()
    validate_hostname_resolution!()
    set_cookie()

    children =
      [
        # Start the Telemetry supervisor
        LivebookWeb.Telemetry,
        # Start the PubSub system
        {Phoenix.PubSub, name: Livebook.PubSub},
        # Start a supervisor for Livebook tasks
        {Task.Supervisor, name: Livebook.TaskSupervisor},
        # Start the storage module
        Livebook.Storage.current(),
        # Start the periodic version check
        Livebook.UpdateCheck,
        # Periodic measurement of system resources
        Livebook.SystemResources,
        # Start the tracker server on this node
        {Livebook.Tracker, pubsub_server: Livebook.PubSub},
        # Start the supervisor dynamically managing sessions
        {DynamicSupervisor, name: Livebook.SessionSupervisor, strategy: :one_for_one},
        # Start the server responsible for associating files with sessions
        Livebook.Session.FileGuard,
        # Start the Node Pool for managing node names
        Livebook.Runtime.NodePool,
        # Start the unique task dependencies
        Livebook.Utils.UniqueTask
      ] ++
        iframe_server_specs() ++
        [
          # Start the Endpoint (http/https)
          # We skip the access url as we do our own logging below
          {LivebookWeb.Endpoint, log_access_url: false}
        ] ++ app_specs()

    opts = [strategy: :one_for_one, name: Livebook.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _} = result ->
        load_lb_env_vars()
        clear_env_vars()
        display_startup_info()
        insert_development_hub()
        result

      {:error, error} ->
        Livebook.Config.abort!(Application.format_error(error))
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    LivebookWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp ensure_directories!() do
    File.mkdir_p!(Livebook.Config.home())
    File.mkdir_p!(Livebook.Config.data_path())
  end

  defp set_local_filesystem!() do
    home =
      Livebook.Config.home()
      |> Livebook.FileSystem.Utils.ensure_dir_path()

    local_filesystem = Livebook.FileSystem.Local.new(default_path: home)
    :persistent_term.put(:livebook_local_filesystem, local_filesystem)
  end

  defp ensure_distribution!() do
    unless Node.alive?() do
      case System.cmd("epmd", ["-daemon"]) do
        {_, 0} ->
          :ok

        _ ->
          Livebook.Config.abort!("""
          Could not start epmd (Erlang Port Mapper Driver). Livebook uses epmd to \
          talk to different runtimes. You may have to start epmd explicitly by calling:

              epmd -daemon

          Or by calling:

              elixir --sname test -e "IO.puts node()"

          Then you can try booting Livebook again
          """)
      end

      {type, name} = get_node_type_and_name()

      case Node.start(name, type) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Livebook.Config.abort!("Could not start distributed node: #{inspect(reason)}")
      end
    end
  end

  import Record
  defrecordp :hostent, Record.extract(:hostent, from_lib: "kernel/include/inet.hrl")

  # See https://github.com/livebook-dev/livebook/issues/302
  defp validate_hostname_resolution!() do
    unless Livebook.Config.longname() do
      [nodename, hostname] = node() |> Atom.to_charlist() |> :string.split(~c"@")

      with {:ok, nodenames} <- :erl_epmd.names(hostname),
           true <- List.keymember?(nodenames, nodename, 0) do
        :ok
      else
        _ ->
          Livebook.Config.abort!("""
          Your hostname \"#{hostname}\" does not resolve to a loopback address (127.0.0.0/8), \
          which indicates something wrong in your OS configuration, or EPMD is not running.

          To address this issue, you might:

            * Consult our Installation FAQ:
              https://github.com/livebook-dev/livebook/wiki/Installation-FAQ

            * If you are using Livebook's CLI or from source, consider using longnames:

                  livebook server --name livebook@127.0.0.1
                  elixir --name livebook@127.0.0.1 -S mix phx.server

            * If the issue persists, please file a bug report

          """)
      end
    end
  end

  defp set_cookie() do
    cookie = Application.fetch_env!(:livebook, :cookie)
    Node.set_cookie(cookie)
  end

  defp get_node_type_and_name() do
    Application.get_env(:livebook, :node) || {:shortnames, random_short_name()}
  end

  defp random_short_name() do
    :"livebook_#{Livebook.Utils.random_short_id()}"
  end

  defp display_startup_info() do
    if Phoenix.Endpoint.server?(:livebook, LivebookWeb.Endpoint) do
      IO.puts("[Livebook] Application running at #{LivebookWeb.Endpoint.access_url()}")
    end
  end

  defp clear_env_vars() do
    for {var, _} <- System.get_env(), config_env_var?(var) do
      System.delete_env(var)
    end
  end

  defp load_lb_env_vars do
    secrets =
      for {"LB_" <> name = var, value} <- System.get_env() do
        System.delete_env(var)
        %Livebook.Secrets.Secret{name: name, value: value}
      end

    Livebook.Secrets.set_temporary_secrets(secrets)
  end

  defp config_env_var?("LIVEBOOK_" <> _), do: true
  defp config_env_var?("RELEASE_" <> _), do: true
  defp config_env_var?(_), do: false

  if Mix.target() == :app do
    defp app_specs, do: [LivebookApp]
  else
    defp app_specs, do: []
  end

  if Livebook.Config.feature_flag_enabled?(:localhost_hub) do
    defp insert_development_hub do
      unless Livebook.Hubs.hub_exists?("local-host") do
        Livebook.Hubs.save_hub(%Livebook.Hubs.Local{
          id: "local-host",
          hub_name: "Localhost",
          hub_color: Livebook.EctoTypes.HexColor.random()
        })
      end
    end
  else
    defp insert_development_hub, do: :ok
  end

  defp iframe_server_specs() do
    server? = Phoenix.Endpoint.server?(:livebook, LivebookWeb.Endpoint)
    port = Livebook.Config.iframe_port()

    if server? do
      http = Application.fetch_env!(:livebook, LivebookWeb.Endpoint)[:http]

      iframe_opts =
        [
          scheme: :http,
          plug: LivebookWeb.IframeEndpoint,
          port: port
        ] ++ Keyword.take(http, [:ip])

      spec = Plug.Cowboy.child_spec(iframe_opts)
      spec = update_in(spec.start, &{__MODULE__, :start_iframe, [port, &1]})
      [spec]
    else
      []
    end
  end

  @doc false
  def start_iframe(port, {m, f, a}) do
    case apply(m, f, a) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:shutdown, {_, _, {{_, {:error, :eaddrinuse}}, _}}}} ->
        iframe_port_in_use(port)

      {:error, {:shutdown, {_, _, {:listen_error, _, :eaddrinuse}}}} ->
        iframe_port_in_use(port)

      {:error, _} = error ->
        error
    end
  end

  defp iframe_port_in_use(port) do
    Livebook.Config.abort!(
      "Failed to start Livebook iframe server because port #{port} is already in use"
    )
  end
end
