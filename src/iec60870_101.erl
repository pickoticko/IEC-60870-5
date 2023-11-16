-module(iec60870_101).

-export([
  start_server/1,
  stop_server/1,
  start_client/1
]).

-define(REQUIRED, {?MODULE, required}).

-define(DEFAULT_SETTINGS, #{
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

start_server(InSettings) ->
  Root = self(),
  Settings = check_settings(maps:merge(?DEFAULT_SETTINGS, InSettings)),
  Module =
    case Settings of
      #{balanced := false} -> iec60870_unbalanced_server;
      _ -> iec60870_balanced_server
    end,
  Server = Module:start(Root, Settings),
  {Module, Server}.

stop_server({Module, Server})->
  Module:stop(Server).

start_client(InSettings) ->
  Settings = check_settings(maps:merge(?DEFAULT_SETTINGS, InSettings)),
  Owner = self(),
  Module =
    case Settings of
      #{balanced := false} -> iec60870_unbalanced_client;
      _ -> iec60870_balanced_client
    end,
  Module:start(Owner, Settings).

check_settings(Settings) ->
  % TODO: Add settings validation
  Settings.