defmodule Canopy.Search do
  @moduledoc """
  Full-text search across messages, finished turns (what an agent ran,
  changed, and concluded) and documents, ranked together in one FTS5 index
  (`search_entries` + `search_fts`, see the `create_search_index`
  migration). The Search page and `canopy_messages_search` both read it.

  Messages and turns are indexed by triggers; documents here, when they are
  created (`index_document/2`), and at boot by `Canopy.Search.Backfill`.
  """

  import Ecto.Query, warn: false

  alias Canopy.Agents.Agent
  alias Canopy.Channels.Channel
  alias Canopy.Documents.{Document, Store}
  alias Canopy.Messages.{Attachment, Message}
  alias Canopy.Repo
  alias Canopy.Schedules.When
  alias Canopy.Search.{Entry, Query}
  alias Canopy.Timeline.Event
  alias Canopy.Users.User

  @default_limit 30
  @max_rows 200
  @text_bytes 1_048_576
  @marks {"\u0002", "\u0003"}

  @doc "The most results one query pages through (offset + limit)."
  def max_rows, do: @max_rows

  @doc "The markers FTS5 wraps matches in by default; the page swaps them for `<mark>`."
  def marks, do: @marks

  @doc """
  Searches the index. Returns `%{results: [result], counts: %{source => n},
  total: n}`: the requested page, the matches per source (ignoring the
  `:sources` filter, so tabs can show every count), and the total for the
  requested sources.

  Options:

    * `:sources` — any of `#{inspect(Entry.sources())}` (default all)
    * `:channel_ids` — only these channels; a document counts when it came
      from one of them or is attached in one (default nil: every channel)
    * `:agent` — an agent id, or `:user` for the local user's own items
    * `:from`, `:to` — `Date`s, local days, inclusive
    * `:include_archived` — also archived channels (default false; items
      with no channel, such as some documents, are always included)
    * `:sort` — `:best` (relevance, with older hits weakened gently),
      `:newest`, or `:rank` (plain relevance) (default `:best`)
    * `:limit` (default #{@default_limit}), `:offset` (default 0); the page
      never reaches past #{@max_rows} rows
    * `:prefix_last` — live typing: the last bare term also matches as a
      prefix (see `Canopy.Search.Query.to_fts/2`)
    * `:min_chars` — the fewest letters and digits worth a search (default 2)
    * `:marks` — `{open, close}` around matches in snippets (default
      `#{inspect(@marks)}`)
    * `:snippet` — `{column, ellipsis, tokens}` (default `{-1, "…", 24}`:
      FTS5 picks the column that matched best)

  A result is `%{source, ref_id, channel, agent, user, thread_id,
  inserted_at, rank, snippet, record}`, where `record` is the `%Message{}`,
  the turn's `%Timeline.Event{}`, or the `%Document{}`.
  """
  def search(text, opts \\ []) do
    fts = Query.to_fts(text, prefix_last: Keyword.get(opts, :prefix_last, false))

    if fts == "" or Query.searchable_length(text) < Keyword.get(opts, :min_chars, 2) do
      empty()
    else
      run(fts, opts)
    end
  end

  defp empty, do: %{results: [], counts: Map.new(Entry.sources(), &{&1, 0}), total: 0}

  defp run(fts, opts) do
    sources = Keyword.get(opts, :sources) || Entry.sources()
    offset = opts |> Keyword.get(:offset, 0) |> max(0) |> min(@max_rows)
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_rows - offset)
    base = filtered(fts, opts)

    found =
      from([e] in base, group_by: e.source, select: {e.source, count(e.id)})
      |> Repo.all()
      |> Map.new()

    counts = Map.new(Entry.sources(), &{&1, Map.get(found, &1, 0)})
    total = sources |> Enum.map(&Map.get(counts, &1, 0)) |> Enum.sum()

    results =
      if limit > 0 and total > offset do
        {open, close} = Keyword.get(opts, :marks, @marks)
        {column, ellipsis, tokens} = Keyword.get(opts, :snippet, {-1, "…", 24})

        base
        |> where([e], e.source in ^sources)
        |> sort(Keyword.get(opts, :sort, :best))
        |> limit(^limit)
        |> offset(^offset)
        |> select([e, f], %{
          entry: e,
          rank: f.rank,
          snippet:
            fragment(
              "snippet(?, ?, ?, ?, ?, ?)",
              f.search_fts,
              ^column,
              ^open,
              ^close,
              ^ellipsis,
              ^tokens
            )
        })
        |> Repo.all()
        |> load()
      else
        []
      end

    %{results: results, counts: counts, total: total}
  end

  defp filtered(fts, opts) do
    from(e in Entry,
      as: :entry,
      join: f in "search_fts",
      on: f.rowid == e.id,
      left_join: c in Channel,
      on: c.id == e.channel_id,
      where: fragment("? MATCH ?", f.search_fts, ^fts)
    )
    |> filter_channels(Keyword.get(opts, :channel_ids))
    |> filter_agent(Keyword.get(opts, :agent))
    |> filter_from(Keyword.get(opts, :from))
    |> filter_to(Keyword.get(opts, :to))
    |> filter_archived(Keyword.get(opts, :include_archived, false))
  end

  defp filter_channels(query, nil), do: query

  defp filter_channels(query, ids) when is_list(ids) do
    attached =
      from(a in Attachment,
        join: m in Message,
        on: m.id == a.message_id,
        where: a.document_id == parent_as(:entry).ref_id and m.channel_id in ^ids,
        select: 1
      )

    where(
      query,
      [e],
      e.channel_id in ^ids or (e.source == "document" and exists(attached))
    )
  end

  defp filter_agent(query, nil), do: query
  defp filter_agent(query, :user), do: where(query, [e], not is_nil(e.user_id))

  defp filter_agent(query, agent_id) when is_binary(agent_id),
    do: where(query, [e], e.agent_id == ^agent_id)

  defp filter_from(query, %Date{} = date),
    do: where(query, [e], e.inserted_at >= ^local_midnight(date))

  defp filter_from(query, _), do: query

  defp filter_to(query, %Date{} = date),
    do: where(query, [e], e.inserted_at < ^local_midnight(Date.add(date, 1)))

  defp filter_to(query, _), do: query

  defp filter_archived(query, true), do: query

  defp filter_archived(query, _),
    do: where(query, [e, _f, c], is_nil(c.id) or c.status == "open")

  defp local_midnight(%Date{} = date),
    do: date |> NaiveDateTime.new!(~T[00:00:00]) |> When.from_local_naive()

  # bm25 is negative, lower is better: dividing by a factor that grows with
  # age weakens older hits gently (x1 today, x0.83 at a week, x0.63 at a year).
  defp sort(query, :best) do
    order_by(query, [e, f],
      asc:
        fragment(
          "? / (1.0 + 0.1 * ln(1.0 + max(0.0, julianday('now') - julianday(?))))",
          f.rank,
          e.inserted_at
        ),
      desc: e.id
    )
  end

  defp sort(query, :newest), do: order_by(query, [e], desc: e.inserted_at, desc: e.id)
  defp sort(query, :rank), do: order_by(query, [e, f], asc: f.rank, asc: e.id)

  # The records behind a page of hits, in three batched queries, plus the
  # channels, agents and user they name. A hit whose record went away in
  # between is dropped.
  defp load([]), do: []

  defp load(hits) do
    entries = Enum.map(hits, & &1.entry)
    ids = fn source -> for %{source: ^source, ref_id: id} <- entries, do: id end

    records =
      Map.merge(
        records(Message, ids.("message"), [:agent, :user, :documents, :thread]),
        Map.merge(
          records(Event, ids.("turn"), [:agent]),
          records(Document, ids.("document"), [:agent, :user])
        )
      )

    channels =
      entries
      |> Enum.map(& &1.channel_id)
      |> by_id(Channel, owner: [], agents: from(a in Agent, order_by: a.name))

    agents = entries |> Enum.map(& &1.agent_id) |> by_id(Agent, [])
    users = entries |> Enum.map(& &1.user_id) |> by_id(User, [])

    for %{entry: e, rank: rank, snippet: snippet} <- hits,
        record = Map.get(records, e.ref_id),
        record != nil do
      %{
        source: e.source,
        ref_id: e.ref_id,
        channel: Map.get(channels, e.channel_id),
        agent: Map.get(agents, e.agent_id),
        user: Map.get(users, e.user_id),
        thread_id: e.thread_id,
        inserted_at: e.inserted_at,
        rank: rank,
        snippet: snippet,
        record: record
      }
    end
  end

  defp records(_schema, [], _preloads), do: %{}

  defp records(schema, ids, preloads) do
    from(r in schema, where: r.id in ^ids, preload: ^preloads)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp by_id(ids, schema, preloads) do
    case ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> %{}
      ids -> records(schema, ids, preloads)
    end
  end

  # -- Documents ---------------------------------------------------------------

  @doc """
  Indexes a document: its filename, its caption, and for a text document the
  first #{div(@text_bytes, 1024 * 1024)} MB of its text (invalid UTF-8
  replaced). `source` is what `Canopy.Documents.create/1` was handed
  (`{:binary, bytes}` or `{:path, file}`); nil reads the stored bytes.
  A document already indexed is left alone.
  """
  def index_document(%Document{} = document, source \\ nil) do
    entry = %Entry{
      source: "document",
      ref_id: document.id,
      channel_id: document.origin_channel_id,
      agent_id: document.agent_id,
      user_id: document.user_id,
      inserted_at: document.inserted_at
    }

    case Repo.insert(entry, on_conflict: :nothing, conflict_target: [:source, :ref_id]) do
      {:ok, %Entry{id: id}} when is_integer(id) ->
        body =
          [document.caption, document_text(document, source)]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join("\n")

        Repo.query!(
          "INSERT INTO search_fts(rowid, title, body, paths) VALUES (?, ?, ?, '')",
          [id, document.filename, body]
        )

        :ok

      {:ok, _already} ->
        :ok
    end
  end

  defp document_text(%Document{kind: "text"} = document, source) do
    case head_bytes(source || {:path, Store.path(document.id)}) do
      {:ok, bytes} -> String.replace_invalid(bytes)
      _ -> ""
    end
  end

  defp document_text(_document, _source), do: ""

  defp head_bytes({:binary, bytes}),
    do: {:ok, binary_part(bytes, 0, min(byte_size(bytes), @text_bytes))}

  defp head_bytes({:path, path}) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @text_bytes)) do
      {:ok, data} when is_binary(data) -> {:ok, data}
      {:ok, :eof} -> {:ok, ""}
      _ -> :error
    end
  end

  @doc """
  Indexes, in batches of `batch` (default 50), every document that has no
  entry yet. Idempotent; returns how many it indexed.
  """
  def index_missing_documents(batch \\ 50), do: index_missing_documents(batch, "", 0)

  defp index_missing_documents(batch, after_id, done) do
    documents =
      from(d in Document,
        left_join: e in Entry,
        on: e.source == "document" and e.ref_id == d.id,
        where: is_nil(e.id) and d.id > ^after_id,
        order_by: d.id,
        limit: ^batch
      )
      |> Repo.all()

    case documents do
      [] ->
        done

      documents ->
        Enum.each(documents, &index_document/1)
        index_missing_documents(batch, List.last(documents).id, done + length(documents))
    end
  end
end
