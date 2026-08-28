defmodule Batata.Test.Subprocess do
  @moduledoc false

  defmodule TimeoutError do
    defexception [:command, :os_pid, :output]

    @impl true
    def message(error) do
      "command timed out and was terminated: #{error.command} (pid #{error.os_pid})"
    end
  end

  def cmd(command, opts), do: cmd(command, [], opts)

  def cmd(command, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    port = open(command, args)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      case collect(port, [], deadline) do
        {:ok, output, status} ->
          {output, status}

        {:timeout, output} ->
          timeout_result(port, command, output)
      end
    after
      close(port)
    end
  end

  def alive?(os_pid) do
    case :os.type() do
      {:win32, _} -> windows_alive?(os_pid)
      {:unix, _} -> unix_alive?(os_pid)
    end
  end

  defp open(command, args) do
    Port.open({:spawn_executable, to_charlist(command)}, [
      :binary,
      :exit_status,
      :hide,
      :stderr_to_stdout,
      :use_stdio,
      args: Enum.map(args, &to_charlist/1)
    ])
  end

  defp collect(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} -> collect(port, [chunk | output], deadline)
      {^port, {:exit_status, status}} -> {:ok, output(output), status}
    after
      remaining -> {:timeout, output(output)}
    end
  end

  defp timeout_result(port, command, output) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        terminate(os_pid)
        {tail, _status} = await_exit(port, [])

        raise TimeoutError,
          command: command,
          os_pid: os_pid,
          output: output <> tail

      nil ->
        {tail, status} = await_exit(port, [])
        {output <> tail, status}
    end
  end

  defp await_exit(port, output) do
    receive do
      {^port, {:data, chunk}} -> await_exit(port, [chunk | output])
      {^port, {:exit_status, status}} -> {output(output), status}
    after
      5_000 -> raise "terminated subprocess was not reaped"
    end
  end

  defp terminate(os_pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"],
          stderr_to_stdout: true
        )

      {:unix, _} ->
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp unix_alive?(os_pid) do
    {_output, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  defp windows_alive?(os_pid) do
    {output, _status} =
      System.cmd(
        "tasklist",
        ["/FI", "PID eq #{os_pid}", "/FO", "CSV", "/NH"],
        stderr_to_stdout: true
      )

    String.contains?(output, ",\"#{os_pid}\",")
  end

  defp output(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, :badarg -> :ok
  end
end
