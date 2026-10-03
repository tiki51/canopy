Mox.defmock(Canopy.OpenCode.ClientMock, for: Canopy.OpenCode.ClientBehaviour)
Mox.defmock(Canopy.GitHub.Mock, for: Canopy.GitHub)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Canopy.Repo, :manual)
