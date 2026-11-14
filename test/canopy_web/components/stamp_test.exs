defmodule CanopyWeb.StampTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Canopy.Schedules.When
  alias CanopyWeb.{SignoffComponents, TimelineComponents}

  # built from local wall-clock times, so the bands hold in any machine time zone
  defp local(naive), do: When.from_local_naive(naive)
  defp stamp(at, now), do: TimelineComponents.stamp_text(local(at), local(now))

  @sat ~N[2026-11-07 23:00:00]

  describe "stamp_text/2" do
    test "today is the time alone, from just after midnight" do
      assert stamp(~N[2026-11-07 00:05:00], @sat) == "00:05"
      assert stamp(~N[2026-11-07 22:58:00], @sat) == "22:58"
    end

    test "yesterday goes by calendar day, not 24 hours" do
      # 11h ago, but yesterday
      assert stamp(~N[2026-11-06 21:48:00], ~N[2026-11-07 09:00:00]) == "Yesterday 21:48"
      # 39h ago, still yesterday
      assert stamp(~N[2026-11-06 08:00:00], @sat) == "Yesterday 08:00"
    end

    test "2 to 6 days ago is the weekday" do
      assert stamp(~N[2026-11-05 17:22:00], @sat) == "Thu 17:22"
      assert stamp(~N[2026-11-01 10:00:00], @sat) == "Sun 10:00"
    end

    test "a week or more ago is the date, with the year only for past years" do
      assert stamp(~N[2026-10-31 10:00:00], @sat) == "Oct 31, 10:00"
      assert stamp(~N[2026-03-04 09:05:00], @sat) == "Mar 4, 09:05"
      assert stamp(~N[2025-11-14 09:12:00], @sat) == "Nov 14, 2025, 09:12"
    end

    test "across New Year the week keeps its words; past it, the old year shows" do
      assert stamp(~N[2026-12-31 21:48:00], ~N[2027-01-01 10:00:00]) == "Yesterday 21:48"
      assert stamp(~N[2026-12-29 17:22:00], ~N[2027-01-02 10:00:00]) == "Tue 17:22"
      assert stamp(~N[2026-12-20 08:00:00], ~N[2027-01-02 10:00:00]) == "Dec 20, 2026, 08:00"
    end

    test "a time in the future gets its date, never a word" do
      assert stamp(~N[2026-11-08 00:30:00], @sat) == "Nov 8, 00:30"
    end

    test "no time is empty" do
      assert TimelineComponents.stamp_text(nil) == ""
    end
  end

  describe "stamp_text/2 at the edges" do
    test "midnight splits the day, however close the times" do
      assert stamp(~N[2026-11-06 23:59:00], ~N[2026-11-07 00:01:00]) == "Yesterday 23:59"
      assert stamp(~N[2026-11-06 23:59:59], ~N[2026-11-07 00:00:00]) == "Yesterday 23:59"
      assert stamp(~N[2026-11-07 00:00:00], ~N[2026-11-07 23:59:00]) == "00:00"
      assert stamp(~N[2026-11-07 00:00:00], ~N[2026-11-07 00:00:00]) == "00:00"
    end

    test "six days is a weekday and seven a date, whatever the hours between" do
      # 144h and 168h back: both six calendar days
      assert stamp(~N[2026-11-01 00:00:00], ~N[2026-11-07 00:01:00]) == "Sun 00:00"
      assert stamp(~N[2026-11-01 00:00:00], ~N[2026-11-07 23:59:00]) == "Sun 00:00"
      # under 145h back, but seven calendar days
      assert stamp(~N[2026-10-31 23:59:00], ~N[2026-11-07 00:01:00]) == "Oct 31, 23:59"
    end

    test "each of the five weekday stamps names the right day" do
      for {days, day} <- [{2, "Thu"}, {3, "Wed"}, {4, "Tue"}, {5, "Mon"}, {6, "Sun"}] do
        at = NaiveDateTime.add(@sat, -days * 86_400, :second)
        assert stamp(at, @sat) == "#{day} 23:00"
      end
    end

    test "month ends, New Year's midnight and a leap day" do
      assert stamp(~N[2026-12-31 23:59:00], ~N[2027-01-01 00:00:00]) == "Yesterday 23:59"
      assert stamp(~N[2026-12-31 10:00:00], ~N[2027-01-06 10:00:00]) == "Thu 10:00"
      assert stamp(~N[2026-12-31 10:00:00], ~N[2027-01-07 10:00:00]) == "Dec 31, 2026, 10:00"
      assert stamp(~N[2025-12-25 09:00:00], ~N[2026-01-01 09:00:00]) == "Dec 25, 2025, 09:00"
      assert stamp(~N[2026-10-31 22:00:00], ~N[2026-11-01 09:00:00]) == "Yesterday 22:00"
      assert stamp(~N[2028-02-29 18:00:00], ~N[2028-03-01 09:00:00]) == "Yesterday 18:00"
    end

    test "a future time later today is the time; on a later day it is a date" do
      assert stamp(~N[2026-11-07 23:01:00], @sat) == "23:01"
      assert stamp(~N[2026-11-12 10:00:00], @sat) == "Nov 12, 10:00"
      assert stamp(~N[2027-01-01 00:30:00], ~N[2026-12-31 23:00:00]) == "Jan 1, 2027, 00:30"
    end

    test "seconds are cut, hours padded, days not" do
      at = local(~N[2026-11-07 21:48:59.999999])
      assert TimelineComponents.stamp_text(at, local(@sat)) == "21:48"
      assert stamp(~N[2026-11-07 09:05:00], @sat) == "09:05"
      assert stamp(~N[2026-03-04 00:00:00], @sat) == "Mar 4, 00:00"
    end

    test "one argument stamps against now; anything but a DateTime is empty" do
      assert TimelineComponents.stamp_text(DateTime.utc_now()) =~ ~r/^\d{2}:\d{2}$/
      assert TimelineComponents.stamp_text(~N[2026-11-07 10:00:00], local(@sat)) == ""
      assert TimelineComponents.stamp_text(nil, local(@sat)) == ""
    end
  end

  test "stamp_title/1 at midnight and in a past year" do
    assert TimelineComponents.stamp_title(local(~N[2026-11-07 00:00:00])) ==
             "Saturday, Nov 7, 2026 at 00:00"

    assert TimelineComponents.stamp_title(local(~N[2025-11-14 09:12:00])) ==
             "Friday, Nov 14, 2025 at 09:12"
  end

  test "<.stamp> puts the instant in datetime, the date in title, and passes attrs on" do
    at = ~U[2026-11-06 21:48:00.123456Z]
    assigns = %{at: at}

    html =
      rendered_to_string(~H"""
      <TimelineComponents.stamp at={@at} class="text-xs" id="s1" data-x="y" />
      """)

    time = LazyHTML.from_fragment(html) |> LazyHTML.query("time#s1")
    assert LazyHTML.attribute(time, "datetime") == ["2026-11-06T21:48:00.123456Z"]
    assert LazyHTML.attribute(time, "title") == [TimelineComponents.stamp_title(at)]
    refute hd(LazyHTML.attribute(time, "title")) =~ ~r/^\d{4}-\d{2}-\d{2}T/
    # a stamp never breaks across lines (B1); the caller's classes come after
    assert LazyHTML.attribute(time, "class") == ["whitespace-nowrap text-xs"]
    assert LazyHTML.attribute(time, "data-x") == ["y"]
    assert time |> LazyHTML.text() |> String.trim() == TimelineComponents.stamp_text(at)
  end

  test "stamp_title/1 is the full local date" do
    assert TimelineComponents.stamp_title(local(~N[2026-11-06 21:48:00])) ==
             "Friday, Nov 6, 2026 at 21:48"

    assert TimelineComponents.stamp_title(nil) == nil
  end

  # -- the surfaces -------------------------------------------------------------

  @title ~r/^[A-Z][a-z]+day, [A-Z][a-z]{2} \d{1,2}, \d{4} at \d{2}:\d{2}$/

  defp ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  # the <time> under `scope`, with its datetime pointing at `at`: {text, title}
  defp time_in(html, scope, at) do
    time =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#{scope} time[datetime='#{DateTime.to_iso8601(at)}']")

    assert Enum.count(time) == 1, "no stamp for #{scope} in:\n#{html}"
    {time |> LazyHTML.text() |> String.trim(), time |> LazyHTML.attribute("title") |> hd()}
  end

  defp message(at) do
    %{
      id: "msg_1",
      channel_id: "chn_1",
      agent_id: nil,
      agent: nil,
      user_id: "usr_1",
      kind: "post",
      body: "Fixed.",
      inserted_at: at,
      sent_to_channel: false,
      thread_id: nil,
      documents: []
    }
  end

  test "a message from two days ago shows its weekday, the full date on hover" do
    at = ago(2)
    assigns = %{message: message(at)}

    html =
      rendered_to_string(~H"""
      <TimelineComponents.message_item message={@message} names={%{}} user_name="Priya" />
      """)

    {text, title} = time_in(html, "#message-msg_1", at)
    assert text =~ ~r/^[A-Z][a-z]{2} \d{2}:\d{2}$/
    assert title =~ @title
  end

  test "a message from today shows the time alone" do
    at = DateTime.utc_now()
    assigns = %{message: message(at)}

    html =
      rendered_to_string(~H"""
      <TimelineComponents.message_item message={@message} names={%{}} user_name="Priya" />
      """)

    {text, _title} = time_in(html, "#message-msg_1", at)
    assert text =~ ~r/^\d{2}:\d{2}$/
  end

  test "a system line from yesterday says so" do
    at = ago(1)

    assigns = %{
      event: %{
        id: "evt_b",
        event_type: "brief_updated",
        agent_id: nil,
        inserted_at: at,
        payload: %{"by" => "user", "body" => "Goal.", "previous" => nil}
      }
    }

    html =
      rendered_to_string(~H"""
      <TimelineComponents.timeline_item id="e" event={@event} names={%{}} user_name="Priya" />
      """)

    {text, title} = time_in(html, "#line-evt_b", at)
    assert text =~ ~r/^Yesterday \d{2}:\d{2}$/
    assert title =~ @title
  end

  test "an activity card from a past year carries the year" do
    at = ago(400)

    assigns = %{
      event: %{
        id: "evt_t",
        channel_id: "chn_1",
        event_type: "agent_turn_completed",
        agent_id: "agt_1",
        inserted_at: at,
        payload: %{
          "outcome" => "ok",
          "tools" => 1,
          "activity" => [
            %{
              "key" => "c1",
              "kind" => "tool",
              "status" => "ok",
              "category" => "other",
              "step" => 0,
              "label" => "Read"
            }
          ]
        }
      }
    }

    html =
      rendered_to_string(~H"""
      <TimelineComponents.timeline_item
        id="e"
        event={@event}
        names={%{"agt_1" => "backend"}}
        user_name="Priya"
        activity={%{}}
      />
      """)

    {text, title} = time_in(html, "#turn-toggle-evt_t", at)
    assert text =~ ~r/^[A-Z][a-z]{2} \d{1,2}, \d{4}, \d{2}:\d{2}$/
    assert title =~ @title
  end

  test "a command line (a system message) from three days ago shows its weekday" do
    at = ago(3)
    assigns = %{message: %{message(at) | kind: "system", body: "/compact"}}

    html =
      rendered_to_string(~H"""
      <TimelineComponents.message_item message={@message} names={%{}} user_name="Priya" />
      """)

    {text, title} = time_in(html, "#message-msg_1", at)
    assert text =~ ~r/^[A-Z][a-z]{2} \d{2}:\d{2}$/
    assert title =~ @title
  end

  test "a system line with no time has no stamp" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <TimelineComponents.system_line id="l" text="Joined" />
      """)

    assert html =~ "Joined"
    refute html =~ "<time"
  end

  test "a freestanding sign-off's hidden row stays without a stamp" do
    assigns = %{
      event: %{
        id: "evt_f",
        ref_id: "so_2",
        inserted_at: ago(10),
        payload: %{"status" => "accepted", "delivered" => "message"}
      }
    }

    html =
      rendered_to_string(~H"""
      <SignoffComponents.signoff_line id="s" event={@event} />
      """)

    assert html =~ ~s(id="signoff-resolved-so_2")
    refute html =~ "<time"
  end

  test "a resolved sign-off from over a week ago shows its date" do
    at = ago(10)

    assigns = %{
      event: %{
        id: "evt_s",
        ref_id: "so_1",
        inserted_at: at,
        payload: %{"status" => "accepted", "title" => "Design options"}
      }
    }

    html =
      rendered_to_string(~H"""
      <SignoffComponents.signoff_line id="s" event={@event} />
      """)

    {text, title} = time_in(html, "#signoff-resolved-so_1", at)
    # early January puts ten days ago in the year before
    assert text =~ ~r/^[A-Z][a-z]{2} \d{1,2}(, \d{4})?, \d{2}:\d{2}$/
    assert title =~ @title
  end
end
