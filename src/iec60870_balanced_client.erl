
-module(iec60870_balanced_client).

-include("iec60870.hrl").
-include("ft12.hrl").

%% API
-export([
  start/2,
  stop/1
]).


start(Owner, Options) ->

  Port = iec60870_balanced:start(_Dir=1, Options ),

  receive
    { connected, Port } ->
      Port ! { connection, self(), Owner },
      Port;
    {'EXIT', Port, Reason}->
      throw( Reason );
    {'EXIT', Owner, Reason}->
      exit(Port, Reason)
  end.

stop( Port )->
  iec60870_balanced:stop( Port ).