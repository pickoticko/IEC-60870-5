-module(iec60870_balanced_client).

-include("iec60870.hrl").
-include("ft12.hrl").

-export([
  start/2,
  stop/1
]).

%% +--------------------------------------------------------------+
%% |                             API                              |
%% +--------------------------------------------------------------+

start(Owner, Options) ->
  PID = iec60870_balanced:start(_Direction = ?FROM_A_TO_B, Options),
  receive
    {connected, PID} ->
      PID ! {connection, self(), Owner},
      PID;
    {'EXIT', PID, Reason} ->
      throw(Reason);
    {'EXIT', Owner, Reason} ->
      exit(PID, Reason)
  end.

stop(PID) ->
  iec60870_balanced:stop(PID).