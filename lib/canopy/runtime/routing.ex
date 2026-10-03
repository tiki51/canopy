defmodule Canopy.Runtime.Routing do
  @moduledoc """
  Model routing (experimental): pure decisions about which profile a wake runs
  on, `:main` (the agent's model and effort) or `:light` (a cheaper one). Off
  for every agent until the Phase 0 spike verifies the engines' behaviour
  (`_claude_docs/architecture/Phase 0 Spike Notes.md`); with routing off every
  wake runs on main, exactly as before.

  Wake kinds are finer than the turn's `trigger` (which keeps its values, so
  spend history by trigger stays continuous):

  | wake_kind | from |
  |---|---|
  | `user_message` | a user message, late answers and approvals included |
  | `agent_mention` | an agent post that @mentions the agent |
  | `agent_thread` | an agent reply in a thread, to its other side |
  | `agent_owner_fallback` | an unaddressed agent post reaching the owner |
  | `delegation_task` | a delegation handed to the agent |
  | `delegation_report` | a delegation the agent handed out, completed or failed |
  | `handoff_request` / `handoff_accepted` / `handoff_rejected` | the handoff events |
  | `scheduled` | a schedule fired |
  | `watch` | a GitHub watch found something |
  | `playbook` / `playbook_nudge` | a playbook run's start, approval, step, or stall nudge |
  | `lock_grant` | a lock the agent waited for |
  | `escalation` | the re-run after `canopy_escalate`, or after a light turn failed |
  | `other` | anything else |

  `route/2` applies the fixed rules (no user-editable table) and three guards
  that force main: a merged wake goes light only if every part would, a warm
  main cache whose light lineage is cold stays on main, and a paused rule
  stays on main. Delegation tasks, playbook steps, and the user's own
  messages always run on main.
  """

  @light_kinds ~w(agent_owner_fallback delegation_report handoff_accepted scheduled)
  @ack_kinds ~w(agent_mention agent_thread)

  # The cache-warmth guard applies from this much context: below it a cold
  # light call costs too little to matter.
  @warm_context 20_000

  @ack_words ~w(thanks thank\ you ok okay got\ it sounds\ good lgtm great done nice perfect ack ty cheers noted)
  @ack_emoji ["👍", "✅", "🙏", "🎉", "👌"]

  @doc "The wake kinds that may go light (an agent mention or thread reply only when it is an acknowledgement)."
  def light_kinds, do: @light_kinds ++ @ack_kinds

  @doc "The kinds that go light only as an acknowledgement (`ack?/1`)."
  def ack_kinds, do: @ack_kinds

  @doc """
  The kind of a wake Canopy sends on its own account (scheduled, watch,
  playbook, lock grant, …), from its trigger. Message, delegation, and
  handoff wakes get theirs from the event (`event_kind/3`).
  """
  def kind_for_trigger("scheduled"), do: "scheduled"
  def kind_for_trigger("watch"), do: "watch"
  def kind_for_trigger("playbook"), do: "playbook"
  def kind_for_trigger("playbook_nudge"), do: "playbook_nudge"
  def kind_for_trigger("lock"), do: "lock_grant"
  def kind_for_trigger("compact"), do: "compact"
  def kind_for_trigger("user"), do: "user_message"
  def kind_for_trigger("delegation"), do: "delegation_task"
  def kind_for_trigger("handoff"), do: "handoff_request"
  def kind_for_trigger(_trigger), do: "other"

  @doc """
  The kind of a wake built from a timeline event for `agent_id`, with the
  router's reason for the target (`Canopy.Runtime.Router.reason/3`, message
  events only) and whether the message reads as an acknowledgement (agent
  messages only). Returns `%{wake_kind, wake_reason, ack}`.
  """
  def event_kind(%{event_type: "message", message: message}, reason, ack?) do
    {kind, ack} =
      if is_nil(message.agent_id) do
        {"user_message", nil}
      else
        kind =
          case reason do
            :mention -> "agent_mention"
            :thread_author -> "agent_thread"
            _ -> "agent_owner_fallback"
          end

        {kind, ack? == true}
      end

    %{wake_kind: kind, wake_reason: reason && Atom.to_string(reason), ack: ack}
  end

  def event_kind(%{event_type: type}, _reason, _ack?) do
    kind =
      case type do
        "delegation_created" -> "delegation_task"
        "delegation_completed" -> "delegation_report"
        "delegation_failed" -> "delegation_report"
        "handoff_requested" -> "handoff_request"
        "handoff_accepted" -> "handoff_accepted"
        "handoff_rejected" -> "handoff_rejected"
        _ -> "other"
      end

    %{wake_kind: kind, wake_reason: nil, ack: nil}
  end

  @doc """
  True when a message body reads as an acknowledgement: 80 characters or
  fewer once trimmed, no question mark, backtick, or URL, and either a word
  from the acknowledgement lexicon (thanks, ok, got it, lgtm, 👍, …) or three
  words or fewer. A lexicon, not a classifier; attachments are the caller's
  check.
  """
  def ack?(body) when is_binary(body) do
    text = String.trim(body)

    text != "" and String.length(text) <= 80 and
      not String.contains?(text, ["?", "`", "http://", "https://", "www."]) and
      (lexicon?(text) or word_count(text) <= 3)
  end

  def ack?(_body), do: false

  defp lexicon?(text) do
    down = String.downcase(text)

    Enum.any?(@ack_emoji, &String.contains?(text, &1)) or
      Enum.any?(@ack_words, fn word ->
        Regex.match?(~r/(^|[^a-z])#{Regex.escape(word)}([^a-z]|$)/u, down)
      end)
  end

  defp word_count(text), do: text |> String.split(~r/\s+/u, trim: true) |> length()

  @doc """
  The profile a wake runs on, and the rule that decided it, as
  `{:main | :light, rule}`.

  `wake` carries `kinds` (`[{wake_kind, ack}]`, one per wake merged into it)
  and `delegation_ids`. `facts`:

    * `enabled?` — the agent has routing on
    * `light?` — a light profile resolves (`Canopy.Agents.effective_profile/2`)
    * `paused` — the wake kinds paused for the agent (`"*"`: every kind)
    * `cache` — `%{main: ms | nil, light: ms | nil, context: tokens}`: when
      the session's last main and light turns ended (monotonic ms) and the
      context of its last turn
    * `now`, `ttl` — monotonic ms now, and how long a provider cache stays warm
  """
  def route(wake, facts) do
    kinds = Map.get(wake, :kinds, [])

    cond do
      not Map.get(facts, :enabled?, false) ->
        {:main, "off"}

      not Map.get(facts, :light?, false) ->
        {:main, "no_light_model"}

      Map.get(wake, :delegation_ids, []) != [] ->
        {:main, "delegation"}

      kinds == [] ->
        {:main, "other"}

      true ->
        kinds |> Enum.map(&kind_route/1) |> combine() |> guard(kinds, facts)
    end
  end

  # One part of a wake on its own: the rules table.
  defp kind_route({kind, _ack}) when kind in @light_kinds, do: {:light, kind}
  defp kind_route({kind, true}) when kind in @ack_kinds, do: {:light, "ack"}
  defp kind_route({kind, _ack}) when kind in @ack_kinds, do: {:main, "not_ack"}
  defp kind_route({"user_message", _}), do: {:main, "user"}
  defp kind_route({"delegation_task", _}), do: {:main, "delegation"}

  defp kind_route({kind, _}) when kind in ["handoff_request", "handoff_rejected"],
    do: {:main, "handoff"}

  defp kind_route({"escalation", _}), do: {:main, "escalation"}
  defp kind_route({kind, _}) when kind in ["playbook", "playbook_nudge"], do: {:main, "playbook"}
  defp kind_route({"watch", _}), do: {:main, "watch"}
  defp kind_route({"lock_grant", _}), do: {:main, "lock"}
  defp kind_route({_kind, _}), do: {:main, "other"}

  # A merged wake goes light only if every part would; the first main part
  # names the rule, as "merged" when there was more than one part.
  defp combine([single]), do: single

  defp combine(routes) do
    case Enum.find(routes, &match?({:main, _}, &1)) do
      nil -> {:light, routes |> List.last() |> elem(1)}
      {:main, _} -> {:main, "merged"}
    end
  end

  defp guard({:main, _} = main, _kinds, _facts), do: main

  defp guard({:light, rule}, kinds, facts) do
    paused = Map.get(facts, :paused, MapSet.new())

    cond do
      MapSet.member?(paused, "*") or Enum.any?(kinds, fn {k, _} -> MapSet.member?(paused, k) end) ->
        {:main, "paused"}

      cache_warm?(Map.get(facts, :cache, %{}), facts) ->
        {:main, "cache_warm"}

      true ->
        {:light, rule}
    end
  end

  @doc """
  The losing case of a switch: the session's main cache is still warm, its
  light lineage is cold, and the context is big enough that re-reading it
  uncached on the light model costs more than staying on main.
  """
  def cache_warm?(cache, facts) do
    now = Map.fetch!(facts, :now)
    ttl = Map.fetch!(facts, :ttl)
    within? = fn at -> is_integer(at) and now - at < ttl end

    within?.(Map.get(cache, :main)) and not within?.(Map.get(cache, :light)) and
      Map.get(cache, :context, 0) >= @warm_context
  end

  @doc "How long a provider's prompt cache is taken to stay warm, in ms (Phase 0 sets it)."
  def cache_ttl_ms, do: Application.get_env(:canopy, :routing_cache_ttl_ms, 300_000)
end
