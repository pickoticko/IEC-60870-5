
-module(iec60870_101).

-define(REQUIRED,{?MODULE, required}).

-define(DEFAULT_SETTINGS,#{
  port => ?REQUIRED,
  balanced => ?REQUIRED,
  address => ?REQUIRED,
  port_options => #{
    baudrate => 9600,
    parity => 0,
    stopbits => 1,
    bytesize => 8
  },
  address_size => 1
}).

%% API
-export([
  start_server/1,
  stop_server/1
]).


start_server(InSettings )->

  Root = self(),

  Settings = check_settings( maps:merge(?DEFAULT_SETTINGS, InSettings) ),

  Module =
    case Settings of
      #{ balanced := false } -> iec60870_unbalanced_server;
      _-> iec60870_balanced_server
    end,

  Server = Module:start(Root, Settings ),
  {Module, Server}.

stop_server( {Module, Server} )->
  Module:stop( Server ).

check_settings( Settings )->
  % TODO
  Settings.