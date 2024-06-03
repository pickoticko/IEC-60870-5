%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_balanced_server).

-include_lib("kernel/include/logger.hrl").
-include("iec60870.hrl").
-include("ft12.hrl").

-export([
  start/2,
  stop/1
]).

%%% +--------------------------------------------------------------+
%%% |                             API                              |
%%% +--------------------------------------------------------------+

start(Root, Options) ->
  PID = spawn(fun() -> init(Root, Options) end),
  receive
    {ready, PID} -> PID;
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

stop(PID) ->
  exit(PID, shutdown).

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init(Root, Options)->
  process_flag(trap_exit, true),
  Port = iec60870_balanced:start(_Direction = ?FROM_B_TO_A, Options),
  Root ! {ready, self()},
  wait_connection(Root, Port, Options).

wait_connection(Root, Port, Options)->
  receive
    {connected, Port} ->
      case iec60870_server:start_connection(Root, {?MODULE, self()}, Port) of
        {ok, Connection} ->
          Port ! {connection, self(), Connection},
          wait_connection(Root, Port, Options);
        error ->
          unlink(Port),
          exit(Port, shutdown),
          NewPort = iec60870_balanced:start(_Direction = ?FROM_B_TO_A, Options),
          wait_connection(Root, NewPort, Options)
      end;
    {'EXIT', Port, Reason} ->
      case Reason of
        connect_error ->
          ?LOG_WARNING("wait connection");
        _ ->
          ?LOG_WARNING("port exit reason: ~p",[Reason])
      end,
      NewPort = iec60870_balanced:start(_Direction = ?FROM_B_TO_A, Options),
      wait_connection(Root, NewPort, Options);
    {'EXIT', Root, Reason} ->
      exit(Port, Reason)
  end.