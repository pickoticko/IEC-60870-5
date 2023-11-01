%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_serial).

-export([
  start_server/1,
  stop_server/1,
  start/1,
  stop/1,
  send/2,
  recv/2,
  check_settings/1
]).

-define(BITRATES, #{
  50 => true,
  75 => true,
  110 => true,
  134 => true,
  150 => true,
  200 => true,
  300 => true,
  600 => true,
  1200 => true,
  2400 => true,
  4800 => true,
  9600 =>  q,
  19200 => true,
  38400 => true,
  57600 => true,
  115200 => true,
  230400 => true,
  460800 => true,
  500000 => true,
  576000 => true,
  921600 => true,
  1000000 => true,
  1152000 => true,
  1500000 => true,
  2000000 => true,
  2500000 => true,
  3000000 => true,
  3500000 => true,
  4000000 => true
}).

-define(MIN_PARITY, 0).
-define(MAX_PARITY, 2).

-define(MIN_STOP_BITS, 1).
-define(MAX_STOP_BITS, 2).

-define(MIN_BYTE_SIZE, 5).
-define(MAX_BYTE_SIZE, 8).

-define(DEFAULT_SETTINGS, #{
  port => "/dev/tty0",
  mode => active,
  bitrate => 9600,
  bytesize => 8,
  parity => 0,
  stopbits => 1
}).

%% +--------------------------------------------------------------+
%% |                            API                               |
%% +--------------------------------------------------------------+

start_server( Settings ) ->
  {Port, PortSettings} = maps:take(port, Settings),
  case eserial:open( Port, PortSettings#{ mode => active } ) of
    {ok, Port} -> Port;
    {error, Reason} -> throw({transport_error, Reason})
  end.

stop_server( Port ) ->
  eserial:close( Port ).

start(#{type := _, port := Port} = Params) ->
  PortSettings = maps:without( [type, port], Params ),
  case eserial:open( Port, PortSettings#{ mode => active } ) of
    {ok, Port} -> Port;
    {error, Reason} -> throw({transport_error, Reason})
  end;

start(Settings) ->
  {error, {bad_arg, Settings}}.

stop(Port) ->
  eserial:close(Port),
  ok.

send(Socket, Data) ->
  eserial:send(Socket, Data).

recv(Port, {Port, data, Data}) ->
  {data, Data};
recv(_Port, _Message) -> false.

%% +--------------------------------------------------------------+
%% |                     Internal Functions                       |
%% +--------------------------------------------------------------+

check_settings(Settings) ->
  Settings = maps:merge(?DEFAULT_SETTINGS, Settings),
  iec60870_lib:check_required_settings(Settings, [bitrate, parity, stopbits, bytesize]),
  [check_setting(K, V) || {K, V} <- maps:to_list(Settings)],
  Settings.

check_setting(port, PortString)
  when is_list(PortString), is_binary(PortString) -> ok;

check_setting(mode, Mode)
  when Mode =:= active, Mode =:= passive -> ok;

check_setting(bitrate, Bitrate) when is_integer(Bitrate) ->
  case maps:is_key(Bitrate, ?BITRATES) of
    {ok, _} -> ok;
    _ -> throw({bad_connection_settings, Bitrate})
  end;

check_setting(parity, Parity)
  when is_integer(Parity), Parity >= ?MIN_PARITY, Parity =< ?MAX_PARITY -> ok;

check_setting(stopbits, Bits)
  when is_integer(Bits), Bits >= ?MIN_STOP_BITS, Bits =< ?MAX_STOP_BITS -> ok;

check_setting(bytesize, Bits)
  when is_integer(Bits), Bits >= ?MIN_BYTE_SIZE, Bits =< ?MAX_BYTE_SIZE -> ok;

check_setting(Key, _) ->
  throw({bad_connection_settings, Key}).


