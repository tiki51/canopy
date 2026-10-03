defmodule CanopyWeb.ComposerTokenParityTest do
  @moduledoc """
  The composer highlight (`assets/js/composer_tokens.js`) must agree with the
  server about what wakes. Each case in `test/support/composer_token_cases.json`
  is derived here from the real server pieces: `Commands.parse/1`, the
  `Messages` mention regex over `CodeMask.mask/1`, `Messages.resolve_mentions/1`
  (agents first, then teams), and `Markdown`'s channel regex. The rendered
  message must highlight the same names. `e2e/tests/composer-tokens.spec.ts`
  runs the tokenizer over the same file.
  """
  use Canopy.DataCase, async: false

  import Canopy.Fixtures

  alias Canopy.Messages
  alias Canopy.Messages.CodeMask
  alias Canopy.Runtime.Commands
  alias CanopyWeb.Markdown

  @fixture Path.expand("../support/composer_token_cases.json", __DIR__)
  @external_resource @fixture
  @cases @fixture |> File.read!() |> Jason.decode!()

  setup do
    base = @cases["context"]
    agents = Map.new(base["agents"] ++ base["inactive"], &{&1, agent_fixture(%{name: &1})})

    for {team, members} <- base["teams"] do
      team_fixture(Enum.map(members, &Map.fetch!(agents, &1)), name: team)
    end

    for name <- base["inactive"], do: {:ok, _} = Canopy.Agents.deactivate(agents[name])

    %{names: Map.new(agents, fn {name, agent} -> {agent.id, name} end)}
  end

  test "the fixture's commands are the server's" do
    assert @cases["context"]["commands"] == Commands.names()
  end

  test "every case matches the server's rules", %{names: names} do
    for %{"name" => name, "text" => text, "expect" => expect} = kase <- @cases["cases"] do
      ctx = context(kase, names)
      expected = Enum.map(expect, &{&1["kind"], &1["text"]})

      assert derive(text, ctx) == expected, "#{name}: #{inspect(text)}"
    end
  end

  test "rendered messages highlight the same mentions and channels", %{names: names} do
    for %{"text" => text, "expect" => expect} = kase <- @cases["cases"],
        Commands.parse(text) == :text do
      ctx = context(kase, names)

      html =
        Markdown.to_html(text,
          mentions: MapSet.union(ctx.agents, MapSet.new(Map.keys(ctx.teams))),
          channels: Map.new(ctx.channels, &{&1, "ch_1"})
        )

      expected = for %{"kind" => k, "text" => t} <- expect, k != "command", do: t
      assert highlighted(html) == expected, "#{kase["name"]}: #{html}"
    end
  end

  test "extract_mentions/1 skips the same code the composer does" do
    for %{"text" => text} <- @cases["cases"], Commands.parse(text) == :text do
      scanned =
        Messages.mention_regex()
        |> Regex.scan(CodeMask.mask(text))
        |> Enum.flat_map(fn [_, name] -> Messages.extract_mentions("@" <> name) end)
        |> MapSet.new()

      assert MapSet.new(Messages.extract_mentions(text)) == scanned, inspect(text)
    end
  end

  defp context(kase, names) do
    get = &Map.get(kase, &1, @cases["context"][&1])

    %{
      agents: MapSet.new(get.("agents")),
      members: MapSet.new(get.("members")),
      teams: get.("teams"),
      channels: MapSet.new(get.("channels")),
      thread: get.("thread"),
      names: names
    }
  end

  # -- Deriving the tokens from the server's pieces ----------------------------

  defp derive(text, ctx) do
    case {Commands.parse(text), ctx.thread} do
      {:text, _} ->
        text_tokens(text, ctx)

      {_command, true} ->
        [{"invalid", command_text(text)}]

      {{:error, _}, false} ->
        [{"command", command_text(text)}]

      {{:command, :stop, _, _}, false} ->
        [{"command", command_text(text)}]

      # a playbook's name and a brief: nothing in it is an agent to highlight
      {{:command, :playbook, _, _}, false} ->
        [{"command", command_text(text)}]

      {{:command, command, target, note}, false} ->
        command_tokens(text, command, target, note, ctx)
    end
  end

  defp command_tokens(text, command, target, note, ctx) do
    [_, target_text] = Regex.run(~r/\A\s*\/\w+\s+(@?[A-Za-z0-9][\w-]*)/, text)
    kind = target_kind(command, target, ctx)
    head = [{"command", command_text(text)} | if(kind, do: [{kind, target_text}], else: [])]

    case command do
      # posted as "@target note", a normal message; the target is the first token
      :invite when kind != nil -> head ++ tl(text_tokens("@#{target} #{note}", ctx))
      _ -> head
    end
  end

  defp target_kind(:invite, target, ctx) do
    if mention_kind(target, ctx), do: "mention"
  end

  defp target_kind(_handoff_or_delegate, target, ctx) do
    case Messages.resolve_mentions("@" <> target) do
      {[_ | _], []} -> agent_kind(target, ctx)
      _ -> nil
    end
  end

  defp command_text(text), do: Regex.run(~r/\A\s*(\/\w+)/, text) |> List.last()

  defp text_tokens(text, ctx) do
    masked = CodeMask.mask(text)

    mentions =
      for [{start, len}, {name_start, name_len}] <-
            Regex.scan(Messages.mention_regex(), masked, return: :index),
          kind = mention_kind(binary_part(text, name_start, name_len), ctx),
          do: {start, kind, binary_part(text, start, len)}

    channels =
      for [{start, len}, {name_start, name_len}] <-
            Regex.scan(Markdown.channel_regex(), masked, return: :index),
          name = String.downcase(binary_part(text, name_start, name_len)),
          MapSet.member?(ctx.channels, name),
          do: {start, "channel", binary_part(text, start, len)}

    (mentions ++ channels) |> Enum.sort() |> Enum.map(fn {_, kind, t} -> {kind, t} end)
  end

  # An agent first, then a team, exactly as the server resolves the name; the
  # composer only knows the agents and teams it was given.
  defp mention_kind(name, ctx) do
    name = String.downcase(name)

    case Messages.resolve_mentions("@" <> name) do
      {[], []} ->
        nil

      {ids, [%{"name" => ^name}]} ->
        if Map.has_key?(ctx.teams, name) do
          if Enum.any?(ids, &MapSet.member?(ctx.members, ctx.names[&1])),
            do: "mention",
            else: "outsider"
        end

      {[_], []} ->
        agent_kind(name, ctx)
    end
  end

  defp agent_kind(name, ctx) do
    cond do
      not MapSet.member?(ctx.agents, name) -> nil
      MapSet.member?(ctx.members, name) -> "mention"
      true -> "outsider"
    end
  end

  defp highlighted(html) do
    mention = Regex.escape(~s(<span class="#{Markdown.mention_class()}">))
    channel = Regex.escape(~s(class="#{Markdown.channel_class()}">))

    ~r/(?:#{mention}|#{channel})([^<]*)</
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end
end
