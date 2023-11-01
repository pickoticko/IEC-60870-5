%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+

-module(iec60870_client).
-behaviour(gen_statem).

-include("iec60870.hrl").

%% +--------------------------------------------------------------+
%% |                           OTP API                            |
%% +--------------------------------------------------------------+

-export([
  start_link/1,
  callback_mode/0,
  code_change/3,
  init/1,
  handle_event/4,
  terminate/3
]).

-export([
  stop/1,
  read/1, read/2,
  subscribe/3, subscribe/2,
  unsubscribe/3, unsubscribe/2,
  send_data/4,
  get_pid/1,
  write/3
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

-record(data, {
  owner,
  socket,
  cache,
  groups,
  settings,
  connection
}).

-record(?MODULE, {
  cache,
  pid,
  scope
}).

-define(SETTINGS, [
  name,
  groups,
  t1
]).

%% +--------------------------------------------------------------+
%% |                           States                             |
%% +--------------------------------------------------------------+

-define(CONNECTING, connecting).
-define(CONNECTED, connected).
-define(ACTIVATION, activation).
-define(INIT_GROUPS, init_groups).
-define(GROUP_REQUEST, group_request).

%% +--------------------------------------------------------------+
%% |                              API                             |
%% +--------------------------------------------------------------+

start_link(InSettings) ->
  Settings = check_settings(InSettings),
  ConnectionPID =
    case gen_statem:start_link(?MODULE, {_OwnerPID = self(), Settings}, []) of
      {ok, PID} -> PID;
      {error, Error} -> throw(Error)
    end,
  receive
    {ready, ConnectionPID, Client}  -> Client;
    {'EXIT', ConnectionPID, Reason} -> throw(Reason)
  end.

stop(#?MODULE{pid = PID}) ->
  gen_statem:stop(PID);
stop(_) -> bad_arg.

subscribe(#?MODULE{scope = ConnectionName}, SubscriberPID)
  when is_pid(SubscriberPID) ->
    esubscribe:subscribe(ConnectionName, update, SubscriberPID);
subscribe(_, _) -> bad_arg.

subscribe(#?MODULE{scope = ConnectionName}, SubscriberPID, AddressList)
  when is_pid(SubscriberPID), is_list(AddressList) ->
  [begin
     esubscribe:subscribe(ConnectionName, Address, SubscriberPID)
   end || Address <- AddressList];

subscribe(#?MODULE{scope = ConnectionName}, SubscriberPID, Address)
  when is_pid(SubscriberPID) ->
    esubscribe:subscribe(ConnectionName, Address, SubscriberPID);
subscribe(_, _, _) -> bad_arg.

unsubscribe(#?MODULE{scope = ConnectionName}, SubscriberPID, Address)
  when is_pid(SubscriberPID) ->
    esubscribe:unsubscribe(ConnectionName, Address, SubscriberPID);
unsubscribe(_, _, _) -> bad_arg.

unsubscribe(#?MODULE{scope = ConnectionName, cache = Cache}, SubscriberPID)
  when is_pid(SubscriberPID) ->
    ets:foldl(
      fun(Object, _) ->
        {Address, _} = Object,
        esubscribe:unsubscribe(ConnectionName, Address, SubscriberPID)
      end, [], Cache);
unsubscribe(_, _) -> bad_arg.

send_data(#?MODULE{pid = PID}, DataObject, Group, COT) ->
  gen_statem:cast(PID, {send, DataObject, Group, COT});
send_data(_, _, _, _) -> bad_arg.

read(#?MODULE{
  cache = Cache
}) ->
  find_group_items(0, Cache);
read(_) -> bad_arg.

read(#?MODULE{cache = Cache}, Address) ->
  iec60870_lib:read_data_object(Cache, Address);
read(_, _) -> bad_arg.

get_pid(#?MODULE{pid = PID}) -> PID.

write(#?MODULE{pid = PID}, IOA, Value) ->
  gen_statem:cast(PID, {IOA, Value}).

find_group_items(_GroupID = 0, Cache) ->
  ets:tab2list( Cache );
find_group_items(GroupID, Cache) ->
  ets:match_object(Cache, {'_',#{ group => GroupID }}).

%% +--------------------------------------------------------------+
%% |                   OTP gen_statem behaviour                   |
%% +--------------------------------------------------------------+

callback_mode() -> [
  handle_event_function,
  state_enter
].

init({OwnerPID, #{
  settings   := #{name := Name, groups := Groups} = Settings,
  connection := Connection,
  transport  := Transport
}}) ->
  ObjectsTable = ets:new(data_objects, [set, protected, {read_concurrency, true}]),
  % Start esubscribe scope for subscriptions
  case esubscribe:start_link(Name) of
    {ok, _PID} -> ok;
    {error, Reason} -> throw(Reason)
  end,
  {ok, {?CONNECTING, Connection, Transport}, #data{
    settings = Settings,
    owner = OwnerPID,
    cache = ObjectsTable,
    groups = Groups
  }}.

terminate(Reason, _, _ClientState) ->
  ?LOGWARNING("Client connection was terminated. Reason: ~p", [Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% +--------------------------------------------------------------+
%% |                      Connecting State                        |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, {?CONNECTING, _, _}, _Data) ->
  {keep_state_and_data, [{state_timeout, 0, connect}]};

handle_event(state_timeout, connect, {?CONNECTING, ConnectionSettings, TransportSettings}, Data)->
  Connection = iec60870_connection:start_link(ConnectionSettings, TransportSettings),
  {next_state, ?ACTIVATION, Data#data{
    connection = Connection
  }};

%% +--------------------------------------------------------------+
%% |                      Activation State                        |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, ?ACTIVATION, #data{
  connection = Connection,
  settings = #{
    t1 := T1
  }
}) ->
  iec60870_connection:cmd(Connection, start_dt_activate),
  {keep_state_and_data, [{state_timeout, T1, timeout}]};

handle_event(info, ?DATA(Connection, start_dt_confirm), ?ACTIVATION, #data{
  connection = Connection,
  settings = #{
    groups := Groups
  }
} = Data)->
  {next_state, {?INIT_GROUPS, Groups}, Data};

handle_event(state_timeout, timeout, ?ACTIVATION, _Data)->
  {stop, startdt_act_reply_timeout};

%% +--------------------------------------------------------------+
%% |                      Init Groups State                       |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, {?INIT_GROUPS, _}, _Data) ->
  {keep_state_and_data, [{state_timeout, 0, init}]};

handle_event(state_timeout, init, {?INIT_GROUPS, [Group | Rest]}, Data) ->
  {next_state, {?GROUP_REQUEST, init, Group, {?INIT_GROUPS, Rest}}, Data};

handle_event(state_timeout, init, {?INIT_GROUPS, []}, #data{
  owner = OwnerPID,
  cache = Cache,
  settings = #{name := Name}
} = Data) ->
  %% All groups have been received, the cache is ready
  %% and therefore we can return a reference to it
  OwnerPID ! {ready, self(), #?MODULE{
    cache = Cache,
    scope = Name,
    pid = self()
  }},
  {next_state, ?CONNECTED, Data};

%% +--------------------------------------------------------------+
%% |                        Group request                         |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, {?GROUP_REQUEST, init, #{id := Group}, _}, #data{
  connection = Connection,
  settings = #{
    t1 := T1
  }
}) ->
  % TODO. handle group versions
  iec60870_connection:cmd(Connection, {group_request, Group}),
  {keep_state_and_data, [{state_timeout, T1, timeout}]};

handle_event(
  info,
  ?DATA(Connection, ?OBJECT(?C_IC_NA_1, confirmation_activation, _IOA, ID)),
  {?GROUP_REQUEST, init, #{id := ID} = Group, NextState},
  #data{connection = Connection} = Data
) ->
  Timeout = maps:get(timeout, Group, undefined),
  Actions =
    if
      is_integer(Timeout) ->
        [{state_timeout, Timeout, timeout}];
      true ->
        []
    end,
  {next_state, {?GROUP_REQUEST, update, #{id := ID} = Group, NextState}, Data, Actions};

handle_event(enter, _PrevState, {?GROUP_REQUEST, update, _, _}, _Date) ->
  keep_state_and_data;

handle_event(
  info,
  ?DATA(Connection, ?OBJECT(Type, {group, ID}, IOA, Value)),
  {?GROUP_REQUEST, update, #{id := ID}, _},
  #data{
    connection = Connection,
    cache = Cache,
    settings = #{name := Name}
  }
) when is_map(Value) ->
  update_value(Name, Cache, Type, IOA, Value#{group => ID}),
  keep_state_and_data;

handle_event(
  info,
  ?DATA(Connection, ?OBJECT(?C_IC_NA_1, termination_activation, _IOA, ID)),
  {?GROUP_REQUEST, update, #{id := ID} = Group, NextState},
  #data{connection = Connection} = Data
) ->
  case Group of
    #{update := UpdateCycle} when is_integer(UpdateCycle) ->
      timer:send_after(UpdateCycle, {update_group, Group, self()});
    _ ->
      ignore
  end,
  {next_state, NextState, Data};

handle_event(state_timeout, timeout, {?GROUP_REQUEST, update, #{id := ID}, _NextState}, _Data) ->
  {stop, {group_request_timeout, ID}};

%% +--------------------------------------------------------------+
%% |                          Connected                           |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, ?CONNECTED, _Data) ->
  keep_state_and_data;

handle_event(info, {update_group, Group, PID}, ?CONNECTED, Data) when PID =:= self() ->
  {next_state, {?GROUP_REQUEST, init, Group, ?CONNECTED}, Data};

handle_event(state_timeout, timeout, ?CONNECTED, _Data) ->
  keep_state_and_data;

%% +--------------------------------------------------------------+
%% |                        Update event                          |
%% +--------------------------------------------------------------+

% From esubscriber notify
handle_event(cast, {IOA, #{type := Type} = Value}, ?CONNECTED, #data{
  connection = Connection,
  cache = Cache,
  settings = #{name := Scope}
}) ->
  iec60870_connection:cmd(Connection, {write_object, IOA, Value, spontaneous}),
  update_value(Scope, Cache, Type, IOA, Value),
  keep_state_and_data;

handle_event(info, ?DATA(Connection, {object, Type, _COT, IOA, Value}), _AnyState, #data{
  connection = Connection,
  cache = Cache,
  settings = #{name := Name}
}) when is_map(Value) ->
  update_value(Name, Cache, Type, IOA, Value),
  keep_state_and_data;

handle_event(info, ?DATA(Connection, {object, ?M_EI_NA_1, _, _, _}), _AnyState, #data{
  connection = Connection
}) ->
  %% TODO: What to do?
  keep_state_and_data;

%% Log unexpected events
handle_event(EventType, EventContent, _AnyState, #data{settings = #{name := Name}}) ->
  ?LOGWARNING("Client connection ~p received unexpected event type ~p, content ~p", [
    Name, EventType, EventContent
  ]),
  keep_state_and_data.

%% +--------------------------------------------------------------+
%% |                      Internal functions                      |
%% +--------------------------------------------------------------+

check_settings(InSettings) when is_map(InSettings) ->
  TransportSettings = check_transport_settings(maps:get(connection, InSettings, undefined)),
  ConnectionSettings = iec60870_connection:check_settings(InSettings),
  ClientSettings = maps:without([connection | maps:keys(ConnectionSettings)], InSettings),
  iec60870_lib:check_required_settings(InSettings, [name, t1]),
  Settings = maps:from_list([{K, check_setting(K, V)} || {K, V} <- maps:to_list(ClientSettings)]),
  #{
    transport => TransportSettings,
    connection => ConnectionSettings,
    settings => Settings
  };
check_settings(_) -> throw(invalid_settings).

check_transport_settings(#{type := Type} = Settings)->
  DriverModule = iec60870_lib:get_driver_module(Type),
  TransportSettings = DriverModule:check_settings(Settings#{type => client}),
  #{
    module => DriverModule,
    settings => TransportSettings
  };
check_transport_settings(Invalid)->
  throw({invalid_connection_settings, Invalid}).

check_setting(name, ConnectionName)
  when is_atom(ConnectionName) -> ConnectionName;

check_setting(groups, Groups) when is_list(Groups) ->
  [case Group of
     #{id := _ID} ->
       Group;
     Group when is_integer(Group) ->
       #{
         id => Group,
         update => undefined,
         timeout => undefined
       };
     _ ->
       throw({bad_group_settings, Group})
   end || Group <- lists:uniq(Groups)];
check_setting(groups, undefined) ->
  [];

check_setting(t1, Timeout)
  when is_number(Timeout) -> Timeout;

check_setting(Key, _) -> throw({bad_connection_settings, Key}).

update_value(Scope, Cache, Type, IOA, InValue) ->

  Group =
    case InValue of
      #{ group := _G } when is_number( _G )-> _G;
      _->
        case ets:lookup( Cache, IOA ) of
          [{_, #{ group :=_G }}] -> _G;
          _-> undefined
        end
    end,

  Value = maps:merge(#{
    group => Group,
    type => Type,
    value => undefined,
    ts => undefined,
    qds => undefined,
    client_ts => erlang:system_time(millisecond)
  }, InValue),

  ets:insert(Cache, {IOA, Value}),
  % Any updates notification
  esubscribe:notify(Scope, update, {IOA, Value}),
  % Only address notification
  esubscribe:notify(Scope, IOA, Value).
