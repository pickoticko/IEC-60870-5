
-module(iec60870_balanced_server).

-include("iec60870.hrl").
-include("ft12.hrl").

%% API
-export([
  start/2,
  stop/1
]).


start(Root, Options) ->
  PID = spawn( fun() -> init(Root, Options) end),
  receive
    {ready, PID} -> PID;
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

stop( PID )->
  exit( PID, shutdown ).

init(Root, Options)->

  process_flag(trap_exit, true),

  Port = iec60870_balanced:start( Options ),
  Root ! { ready, self() },

  wait_connection( Root, Port, Options ).

wait_connection( Root, Port, Options )->
  receive
    { connected, Port } ->
      case iec60870_server:start_connection(Root, {?MODULE,self()}, self() ) of
        {ok, Connection} ->
          Port ! { connection, self(), Connection };
        error->
          unlink( Port ),
          exit(Port, shutdown),
          NewPort = iec60870_balanced:start(_Dir = 0, Options ),
          wait_connection( Root, NewPort, Options )
      end;
    {'EXIT', Port, Reason}->
      case Reason of
        connect_error->
          ?LOGDEBUG("wait connection");
        _->
          ?LOGWARNING("port exit reason: ~p",[Reason])
      end,
      NewPort = iec60870_balanced:start(_Dir =0, Options ),
      wait_connection( Root, NewPort, Options );
    {'EXIT', Root, Reason}->
      exit(Port, Reason)
  end.