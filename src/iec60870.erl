-module(iec60870).

-export([
  start_server/1,
  start_client/1,
  stop/1,
  subscribe/2, subscribe/3,
  unsubscribe/2, unsubscribe/3,
  read/1, read/2,
  get_pid/1,
  write/3,
  test_write/1
]).

start_server(ConnectionSettings) ->
  iec60870_server:start(ConnectionSettings).

start_client(ConnectionSettings) ->
  iec60870_client:start(ConnectionSettings).

stop(ClientOrServer) ->
  Module = element(1, ClientOrServer),
  Module:stop(ClientOrServer).

subscribe(ClientOrServer, SubscriberPID) ->
  Module = element(1, ClientOrServer),
  Module:subscribe(ClientOrServer, SubscriberPID).

subscribe(ClientOrServer, SubscriberPID, Address) ->
  Module = element(1, ClientOrServer),
  Module:subscribe(ClientOrServer, SubscriberPID, Address).

unsubscribe(ClientOrServer, SubscriberPID, Address) ->
  Module = element(1, ClientOrServer),
  Module:unsubscribe(ClientOrServer, SubscriberPID, Address).

unsubscribe(ClientOrServer, SubscriberPID) ->
  Module = element(1, ClientOrServer),
  Module:remove_subscriber(ClientOrServer, SubscriberPID).

write(ClientOrServer, IOA, Value) ->
  Module = element(1, ClientOrServer),
  Module:write(ClientOrServer, IOA, Value).

read(ClientOrServer) ->
  Module = element(1, ClientOrServer),
  Module:read(ClientOrServer).

read(ClientOrServer, Address) ->
  Module = element(1, ClientOrServer),
  Module:read(ClientOrServer, Address).

get_pid(ClientOrServer)->
  Module = element(1, ClientOrServer),
  Module:get_pid(ClientOrServer).

test_write(Server) ->
  test_write(Server, 0).

test_write(_, 1000) ->
  ok;
test_write(Server, Count) ->
  iec60870:write(Server, Count,     #{value => 0, siq => 128, type => 1}),
  iec60870:write(Server, Count + 1, #{value => 0, diq => 128, type => 3}),
  iec60870:write(Server, Count + 2, #{value => 0, qds => 128, type => 7}),
  iec60870:write(Server, Count + 3, #{value => 0, qds => 128, type => 11}),
  iec60870:write(Server, Count + 4, #{value => 0, type => 21}),
  test_write(Server, Count + 5).