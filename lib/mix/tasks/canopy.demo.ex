defmodule Mix.Tasks.Canopy.Demo do
  @shortdoc "Creates the demo repository and a #payment-retries channel"
  @moduledoc """
  Sets up the Canopy demo: a tiny billing repository with a planted duplicate-charge
  bug under `tmp/demo-repo`, the OpenCode identity plugin inside it, a registered
  repository, and a `payment-retries` channel owned by @backend with @researcher as
  a member. Idempotent.

      mix canopy.demo

  Then start OpenCode (`opencode serve --port 4096`), run `mix phx.server`, open the
  channel, and post:

      Invoices are occasionally charged twice. Read payments.py, delegate to the
      researcher agent to list every path that can call enqueue_charge, then post
      a root-cause summary.
  """

  use Mix.Task

  @demo_dir "tmp/demo-repo"

  @files %{
    ".gitignore" => """
    .opencode/
    __pycache__/
    """,
    "README.md" => """
    # Billing service (demo)

    A tiny billing worker used to demonstrate Canopy. Invoices are occasionally charged twice.
    Run the tests with `python3 -m unittest`.
    """,
    "payments.py" => """
    \"\"\"Payment worker with a subtle duplicate-charge bug.\"\"\"

    from collections import deque

    queue = deque()


    def enqueue_charge(invoice_id, attempt=1):
        queue.append((invoice_id, attempt))


    class PaymentWorker:
        \"\"\"Charges invoices; retries on transient failures.\"\"\"

        def __init__(self, gateway):
            self.gateway = gateway

        def process(self, invoice_id, attempt=1):
            try:
                return self.gateway.charge(invoice_id)
            except TimeoutError:
                # Retry path 1: the worker re-enqueues itself.
                if attempt < 3:
                    enqueue_charge(invoice_id, attempt + 1)
                raise


    class RetryScheduler:
        \"\"\"Sweeps failed invoices every minute and re-enqueues them.\"\"\"

        def __init__(self, failed_invoices):
            self.failed_invoices = failed_invoices

        def sweep(self):
            # Retry path 2: independent of PaymentWorker's own retry.
            for invoice_id in list(self.failed_invoices):
                enqueue_charge(invoice_id)
    """,
    "test_payments.py" => """
    import unittest

    import payments


    class FlakyGateway:
        def __init__(self):
            self.calls = 0

        def charge(self, invoice_id):
            self.calls += 1
            if self.calls == 1:
                raise TimeoutError("gateway timeout")
            return "charged"


    class PaymentTests(unittest.TestCase):
        def setUp(self):
            payments.queue.clear()

        def test_retry_after_timeout(self):
            worker = payments.PaymentWorker(FlakyGateway())
            with self.assertRaises(TimeoutError):
                worker.process("inv_1")
            self.assertEqual(len(payments.queue), 1)


    if __name__ == "__main__":
        unittest.main()
    """
  }

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    path = Path.expand(@demo_dir)
    create_repo(path)
    File.write!(Path.join(path, ".gitignore"), @files[".gitignore"])
    File.mkdir_p!(Path.join(path, ".opencode/plugins"))
    File.write!(Path.join(path, ".opencode/plugins/canopy.js"), Canopy.MCP.plugin_source())

    repository =
      Canopy.Repositories.get_by_path(path) ||
        Canopy.Repositories.create(%{name: "billing-demo", path: path}, allow_outside_home: true)
        |> elem(1)

    backend =
      Canopy.Agents.get_by_name("backend") || Mix.raise("run `mix run priv/repo/seeds.exs` first")

    researcher = Canopy.Agents.get_by_name("researcher")

    channel =
      Canopy.Channels.get_by_name(repository.id, "payment-retries") ||
        Canopy.Channels.create(%{
          repository_id: repository.id,
          name: "payment-retries",
          topic: "Invoices are occasionally charged twice",
          owner_agent_id: backend.id,
          agent_ids: Enum.map([backend, researcher], & &1.id)
        })
        |> elem(1)

    Mix.shell().info("""
    Demo ready.
      repository  #{repository.name} at #{path}
      channel     ##{channel.name} (owner @backend, members @backend @researcher)
      plugin      #{path}/.opencode/plugins/canopy.js (project-level; copy to
                  ~/.config/opencode/plugins/canopy.js to cover every repository)

    Next: `opencode serve --port 4096`, then `mix phx.server`, open http://localhost:4000/channels/#{channel.id}
    """)
  end

  defp create_repo(path) do
    unless File.dir?(Path.join(path, ".git")) do
      File.mkdir_p!(path)
      Enum.each(@files, fn {name, body} -> File.write!(Path.join(path, name), body) end)
      git!(path, ["init", "-q", "-b", "main"])
      git!(path, ["add", "-A"])

      git!(path, [
        "-c",
        "user.email=demo@canopy.local",
        "-c",
        "user.name=Canopy Demo",
        "commit",
        "-q",
        "-m",
        "Billing worker with two retry paths"
      ])
    end
  end

  defp git!(path, args) do
    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> Mix.raise("git #{Enum.join(args, " ")} failed (#{code}): #{out}")
    end
  end
end
