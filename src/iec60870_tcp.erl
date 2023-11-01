%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_tcp).

-export([
  start_server/1,
  stop_server/1,
  start/1,
  stop/1,
  send/2,
  recv/2,
  check_settings/1
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

-define(DEFAULT_CONNECT_TIMEOUT, 30000).

-define(DEFAULT_PORT, 2404).
-define(MAX_PORT_VALUE, 65535).
-define(MIN_PORT_VALUE, 0).

-define(IP_OCTET_RANGE, 255).
-define(IP_LENGTH, 4).

%% +--------------------------------------------------------------+
%% |                            API                               |
%% +--------------------------------------------------------------+

start_server(#{port := Port}) ->
  case gen_tcp:listen(Port, [binary, {active, true}, {packet, raw}]) of
    {ok, Socket} -> Socket;
    {error, Reason} -> throw({transport_error, Reason})
  end.

stop_server(ListenSocket) ->
  gen_tcp:shutdown( ListenSocket, read_write ).


start(#{type := client, host := Host, port := Port} = Params) ->
  Timeout = maps:get(timeout, Params, ?DEFAULT_CONNECT_TIMEOUT),
  case inet:getaddr(Host, inet) of
    {ok, HostIP} ->
      gen_tcp:connect(HostIP, Port, [binary, {active, true}, {packet, raw}], Timeout);
    Error ->
      Error
  end;

start(#{type := server, server := ListenSocket}) ->
  gen_tcp:accept(ListenSocket);

start(Settings) ->
  {error, {bad_arg, Settings}}.

stop(Channel) ->
  gen_tcp:close(Channel),
  ok.

send(Socket, Data) ->
  gen_tcp:send(Socket, Data).

recv(Socket, {tcp_closed, Socket}) ->
  {closed, tcp_closed};
recv(Socket, {tcp_error, Socket, Reason}) ->
  {closed, Reason};
recv(Socket, {tcp_passive, Socket}) ->
  {closed, tcp_passive};
recv(Socket, {tcp, Socket, Message}) ->
  {data, Message};
recv(_Socket, _Message) -> false.

%% +--------------------------------------------------------------+
%% |                     Internal Functions                       |
%% +--------------------------------------------------------------+

check_settings(#{type := client} = Settings) ->
  check_client_settings(Settings);

check_settings(#{type := server} = Settings) ->
  check_server_settings(Settings).

check_client_settings(Settings)->
  Settings = maps:merge(#{port => ?DEFAULT_PORT}, Settings),
  iec60870_lib:check_required_settings(Settings, [host]),
  [check_setting(K, V) || {K, V} <- maps:to_list(Settings)],
  Settings.

check_server_settings(Settings)->
  % TODO: Check server settings
  Settings.

check_setting(host, IPv4) when is_tuple(IPv4) ->
  case tuple_to_list(IPv4) of
    IP when length(IP) =:= ?IP_LENGTH ->
      case [Octet || Octet <- IP, is_integer(Octet), Octet >= 0, Octet =< ?IP_OCTET_RANGE] of
        IP -> ok;
        _  -> throw({bad_host_ip, IPv4})
      end;
    _ -> throw({bad_host_ip, IPv4})
  end;

check_setting(port, Port)
  when is_number(Port), Port >= ?MIN_PORT_VALUE, Port =< ?MAX_PORT_VALUE -> ok;

check_setting(type, Type)
  when Type =:= client; Type =:= server -> ok;

check_setting(timeout, Timeout)
  when is_number(Timeout); Timeout =:= infinity -> ok;

check_setting(Key, _) ->
  throw({bad_connection_settings, Key}).


