defmodule Livebook.Runtime.ErlDist.NodeManager do
  @moduledoc false

  # The primary Livebook process started on a remote node.
  #
  # This process is responsible for initializing the node
  # with necessary runtime configuration and then starting
  # runtime server processes, one per runtime.
  # This approach allows for multiple runtimes connected
  # to the same node, while preserving the necessary
  # cleanup semantics.
  #
  # The manager process terminates as soon as the last runtime
  # server terminates. Upon termination the manager reverts the
  # runtime configuration back to the initial state.

  use GenServer

  alias Livebook.Runtime.ErlDist

  @name __MODULE__

  @doc """
  Starts the node manager.

  ## Options

    * `:unload_modules_on_termination` - whether to unload all
      Livebook related modules from the node on termination.
      Defaults to `true`.

    * `:anonymous` - configures whether manager should
      be registered under a global name or not.
      In most cases we enforce a single manager per node
      and identify it by a name, but this can be opted-out
      from by using this option. Defaults to `false`.

    * `:auto_termination` - whether to terminate the manager
      when the last runtime server terminates. Defaults to `true`.

    * `:parent_node` - indicates which node spawned the node manager.
       It is used to disconnect the node when the server terminates,
       which happens when the last session using the node disconnects.
       Defaults to `nil`

    * `:capture_orphan_logs` - whether to capture logs out of Livebook
      evaluator's scope. Defaults to `true`
  """
  def start(opts \\ []) do
    {opts, gen_opts} = split_opts(opts)
    GenServer.start(__MODULE__, opts, gen_opts)
  end

  @doc """
  Starts the node manager with link.

  See `start/1` for available options.
  """
  def start_link(opts \\ []) do
    {opts, gen_opts} = split_opts(opts)
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  defp split_opts(opts) do
    {anonymous?, opts} = Keyword.pop(opts, :anonymous, false)

    gen_opts = [
      name: if(anonymous?, do: nil, else: @name)
    ]

    {opts, gen_opts}
  end

  @doc """
  Starts a new `Livebook.Runtime.ErlDist.RuntimeServer` for evaluation.
  """
  @spec start_runtime_server(node() | pid(), keyword()) :: pid()
  def start_runtime_server(node_or_pid, opts \\ []) do
    GenServer.call(server(node_or_pid), {:start_runtime_server, opts})
  end

  defp server(pid) when is_pid(pid), do: pid
  defp server(node) when is_atom(node), do: {@name, node}

  @impl true
  def init(opts) do
    unload_modules_on_termination = Keyword.get(opts, :unload_modules_on_termination, true)
    auto_termination = Keyword.get(opts, :auto_termination, true)
    parent_node = Keyword.get(opts, :parent_node)
    capture_orphan_logs = Keyword.get(opts, :capture_orphan_logs, true)

    ## Initialize the node

    Process.flag(:trap_exit, true)

    {:ok, server_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    # Register our own standard error IO device that proxies
    # to sender's group leader.
    original_standard_error = Process.whereis(:standard_error)
    {:ok, io_forward_gl_pid} = ErlDist.IOForwardGL.start_link()
    Process.unregister(:standard_error)
    Process.register(io_forward_gl_pid, :standard_error)

    Logger.add_backend(Livebook.Runtime.ErlDist.LoggerGLBackend)

    # Set `ignore_module_conflict` only for the NodeManager lifetime.
    initial_ignore_module_conflict = Code.compiler_options()[:ignore_module_conflict]
    Code.compiler_options(ignore_module_conflict: true)

    tmp_dir = make_tmp_dir()

    if ebin_path = ebin_path(tmp_dir) do
      File.mkdir_p!(ebin_path)
      Code.prepend_path(ebin_path)
    end

    {:ok,
     %{
       unload_modules_on_termination: unload_modules_on_termination,
       auto_termination: auto_termination,
       server_supervisor: server_supervisor,
       runtime_servers: [],
       initial_ignore_module_conflict: initial_ignore_module_conflict,
       original_standard_error: original_standard_error,
       parent_node: parent_node,
       capture_orphan_logs: capture_orphan_logs,
       tmp_dir: tmp_dir
     }}
  end

  @impl true
  def terminate(_reason, state) do
    Code.compiler_options(ignore_module_conflict: state.initial_ignore_module_conflict)

    Process.unregister(:standard_error)
    Process.register(state.original_standard_error, :standard_error)

    Logger.remove_backend(Livebook.Runtime.ErlDist.LoggerGLBackend)

    if state.unload_modules_on_termination do
      ErlDist.unload_required_modules()
    end

    if state.parent_node do
      Node.disconnect(state.parent_node)
    end

    if ebin_path = ebin_path(state.tmp_dir) do
      Code.delete_path(ebin_path)
    end

    if tmp_dir = state.tmp_dir do
      File.rm_rf!(tmp_dir)
    end

    :ok
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, state) do
    if pid in state.runtime_servers do
      case update_in(state.runtime_servers, &List.delete(&1, pid)) do
        %{runtime_servers: [], auto_termination: true} = state ->
          {:stop, :shutdown, state}

        state ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:orphan_log, _output} = message, state) do
    if state.capture_orphan_logs do
      for pid <- state.runtime_servers, do: send(pid, message)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:start_runtime_server, opts}, _from, state) do
    opts =
      opts
      |> Keyword.put_new(:ebin_path, ebin_path(state.tmp_dir))
      |> Keyword.put_new(:tmp_dir, child_tmp_dir(state.tmp_dir))

    {:ok, server_pid} =
      DynamicSupervisor.start_child(state.server_supervisor, {ErlDist.RuntimeServer, opts})

    Process.monitor(server_pid)
    state = update_in(state.runtime_servers, &[server_pid | &1])
    {:reply, server_pid, state}
  end

  defp make_tmp_dir() do
    path = Path.join([System.tmp_dir!(), "livebook_runtime", random_id()])

    if File.mkdir_p(path) == :ok do
      path
    end
  end

  defp ebin_path(nil), do: nil
  defp ebin_path(tmp_dir), do: Path.join(tmp_dir, "ebin")

  defp child_tmp_dir(nil), do: nil
  defp child_tmp_dir(tmp_dir), do: Path.join(tmp_dir, random_id())

  defp random_id() do
    :crypto.strong_rand_bytes(20) |> Base.encode32(case: :lower)
  end
end
