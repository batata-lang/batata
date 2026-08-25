defmodule Batata.NativeDeps.Subprocess do
  @moduledoc false

  @signals [:sigterm]

  def run!(command, args, opts) do
    port = open(command, args, opts)

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> run_port(port, os_pid)
      nil -> await_exit(port)
    end
  end

  defp run_port(port, os_pid) do
    try do
      traps = trap_termination(os_pid)

      try do
        await_exit(port)
      after
        untrap_termination(traps)
      end
    after
      if Port.info(port) do
        terminate(os_pid)
        close(port)
      end
    end
  end

  defp open(command, args, opts) do
    port_opts = [
      :binary,
      :exit_status,
      :hide,
      :stderr_to_stdout,
      :use_stdio,
      args: Enum.map(args, &to_charlist/1)
    ]

    port_opts =
      case opts[:cd] do
        nil -> port_opts
        path -> [{:cd, to_charlist(path)} | port_opts]
      end

    port_opts =
      case opts[:env] do
        nil -> port_opts
        env -> [{:env, Enum.map(env, &port_env/1)} | port_opts]
      end

    Port.open({:spawn_executable, to_charlist(command)}, port_opts)
  end

  defp await_exit(port) do
    receive do
      {^port, {:data, output}} ->
        IO.binwrite(output)
        await_exit(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  defp trap_termination(os_pid) do
    Enum.flat_map(@signals, fn signal ->
      id = make_ref()

      case System.trap_signal(signal, id, fn ->
             terminate(os_pid)
             :ok
           end) do
        {:ok, ^id} -> [{signal, id}]
        {:error, :not_sup} -> []
      end
    end)
  end

  defp untrap_termination(traps) do
    Enum.each(traps, fn {signal, id} -> System.untrap_signal(signal, id) end)
  end

  defp terminate(os_pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"],
          stderr_to_stdout: true
        )

      {:unix, _} ->
        pids = unix_descendants(os_pid) ++ [os_pid]

        System.cmd("kill", ["-KILL" | Enum.map(pids, &Integer.to_string/1)],
          stderr_to_stdout: true
        )
    end

    :ok
  end

  defp unix_descendants(root) do
    {output, _status} = System.cmd("ps", ["-e", "-o", "pid=,ppid="], stderr_to_stdout: true)

    children =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line) do
          [pid, parent] -> [{String.to_integer(parent), String.to_integer(pid)}]
          _ -> []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    descendants(root, children)
  end

  defp descendants(parent, children) do
    Enum.flat_map(Map.get(children, parent, []), fn child ->
      descendants(child, children) ++ [child]
    end)
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp port_env({name, nil}), do: {to_charlist(name), false}
  defp port_env({name, value}), do: {to_charlist(name), to_charlist(value)}
end
