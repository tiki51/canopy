defmodule CanopyWeb.PageController do
  use CanopyWeb, :controller

  alias Canopy.Channels
  alias CanopyWeb.OnboardingLive

  @doc """
  Home: the first open channel, or the repositories screen when there is
  none. First-run setup opens over whichever it is (`CanopyWeb.Nav`); a
  `?setup=<step>` is passed on so it opens at that step.
  """
  def home(conn, params) do
    path =
      case Enum.reject(Channels.list(), &Channels.dm?/1) do
        [channel | _] -> ~p"/channels/#{channel.id}"
        [] -> ~p"/repositories"
      end

    case OnboardingLive.step_for(params["setup"]) do
      nil -> redirect(conn, to: path)
      step -> redirect(conn, to: path <> "?" <> URI.encode_query(%{"setup" => step}))
    end
  end

  @doc """
  The old first-run setup page: home, with the setup modal open (at the step
  an old `?step=` link names).
  """
  def welcome(conn, params) do
    step = OnboardingLive.step_for(params["step"]) || "you"
    redirect(conn, to: ~p"/?#{[setup: step]}")
  end
end
