defmodule Batata.NativeDeps.SubprocessTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Batata.NativeDeps.Subprocess

  test "streams output and returns the child exit status" do
    git = System.find_executable("git")

    assert capture_io(fn ->
             assert Subprocess.run!(git, ["--version"], []) == 0
           end) =~ "git version"

    assert capture_io(fn ->
             assert Subprocess.run!(git, ["not-a-command"], []) != 0
           end) =~ "not-a-command"
  end

  test "terminates the child when the wrapper receives SIGTERM" do
    if match?({:unix, _}, :os.type()) do
      tmp =
        Path.join(System.tmp_dir!(), "batata-subprocess-#{System.unique_integer([:positive])}")

      child_file = Path.join(tmp, "child.pid")
      File.mkdir_p!(tmp)

      sh = System.find_executable("sh")
      elixir = System.find_executable("elixir")
      ebin = Subprocess |> :code.which() |> Path.dirname()

      code =
        "Batata.NativeDeps.Subprocess.run!(#{inspect(sh)}, " <>
          "[\"-c\", #{inspect("sleep 120 & echo $! > #{child_file}; wait")}], [])"

      wrapper =
        Port.open({:spawn_executable, to_charlist(elixir)}, [
          :binary,
          :exit_status,
          :hide,
          :stderr_to_stdout,
          args: Enum.map(["-pa", ebin, "-e", code], &to_charlist/1)
        ])

      wrapper_pid = wrapper |> Port.info(:os_pid) |> elem(1)

      on_exit(fn ->
        kill(wrapper_pid, "-KILL")

        if File.regular?(child_file) do
          child_file |> File.read!() |> String.trim() |> String.to_integer() |> kill("-KILL")
        end

        File.rm_rf!(tmp)
      end)

      assert eventually(fn -> File.regular?(child_file) end)
      child_pid = child_file |> File.read!() |> String.trim() |> String.to_integer()
      assert alive?(child_pid)

      kill(wrapper_pid, "-TERM")

      assert eventually(fn -> not alive?(child_pid) end)
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(25)
        eventually(fun, attempts - 1)
    end
  end

  defp alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp kill(pid, signal) do
    System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end
