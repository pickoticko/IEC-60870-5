%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_server).
-behaviour(gen_statem).

-include("iec60870.hrl").

-export([
  start/1,
  stop/1,
  write/3,
  read/1, read/2,
  get_pid/1
]).

-export([
  callback_mode/0,
  code_change/3,
  init/1,
  handle_event/4,
  terminate/3
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+
-record(?MODULE, {
  cache,
  pid,
  scope
}).

-record(data, {
  owner,
  socket,
  cache,
  groups,
  settings,
  connection
}).

%% +--------------------------------------------------------------+
%% |                           States                             |
%% +--------------------------------------------------------------+

-define(WAIT_CONNECTION, wait_connection).
-define(WAIT_ACTIVATION, wait_activation).
-define(RUNNING, running).

% API
get_pid(#?MODULE{pid = PID}) -> PID.

write(#?MODULE{
  cache = Cache,
  scope = Scope
}, IOA, #{type := Type} = InValue )->
  update_value( Scope, Cache, Type, IOA, InValue ).

read(#?MODULE{
  cache = Cache
}) ->
  find_group_items(0, Cache);
read(_) -> bad_arg.

read(#?MODULE{cache = Cache}, Address) ->
  iec60870_lib:read_data_object(Cache, Address);
read(_, _) -> bad_arg.

start(InSettings) ->
  Settings = check_settings(InSettings),
  Self = self(),
  PID = spawn_link(fun()->init_server(Self, Settings) end),
  receive
    {ready, PID, ServerRef}  ->
      unlink(PID),
      ServerRef;
    {'EXIT', PID, Reason} ->
      throw(Reason)
  end.

init_server(Owner, #{
  transport := Transport,
  settings := #{ name := Name }
} = Settings )->

  process_flag(trap_exit, true),

  Server = init_transport( Transport ),

  Cache = ets:new(data_objects, [
    set,
    public,
    {read_concurrency, true},
    {write_concurrency, auto}
  ]),

  case esubscribe:start_link( Name ) of
    {ok, _PID} -> ok;
    {error, Reason} -> throw(Reason)
  end,

  Owner ! {ready, self(), #?MODULE{
    pid = self(),
    cache = Cache,
    scope = Name
  }},

  % Start first listening process
  gen_statem:start(?MODULE, Settings#{
    owner       => self(),
    server      => Server,
    cache       => Cache
  }, []),

  receive
    {'EXIT' ,_, StopReason}->
      ?LOGINFO("stop server, reason: ~p", [StopReason] ),
      stop_server( Transport, Server ),
      exit(StopReason)
  end.

init_transport(#{
  module := DriverModule,
  settings := TransportSettings
}) ->
  DriverModule:start_server(TransportSettings).

stop_server( #{
  module := DriverModule
}, Server )->
  DriverModule:stop_server(Server).

check_transport_settings(#{type := Type} = Settings)->
  DriverModule = iec60870_lib:get_driver_module(Type),
  TransportSettings = DriverModule:check_settings(Settings#{type => server}),
  #{
    module => DriverModule,
    settings => TransportSettings
  };
check_transport_settings(Invalid)->
  throw({invalid_connection_settings, Invalid}).

check_settings(InSettings) ->
  TransportSettings = check_transport_settings(maps:get(connection, InSettings, undefined)),
  ConnectionSettings = iec60870_connection:check_settings(InSettings),
  ServerSettings = maps:without([connection | maps:keys(ConnectionSettings)], InSettings),
  iec60870_lib:check_required_settings(InSettings, [ name, t1 ]),
  Settings = maps:from_list([{K, check_setting(K, V)} || {K, V} <- maps:to_list(ServerSettings)]),
  #{
    transport => TransportSettings,
    connection => ConnectionSettings,
    settings => Settings
  }.

check_setting(name, ConnectionName)
  when is_atom(ConnectionName) -> ConnectionName;

check_setting(t1, Timeout)
  when is_number(Timeout) -> Timeout;

check_setting(groups, Groups) when is_list(Groups) ->
  [case Group of
     #{id := _ID} ->
       Group;
     Group when is_integer(Group) ->
       #{
         id => Group,
         update => undefined
       };
     _ ->
       throw({bad_group_settings, Group})
   end || Group <- lists:uniq(Groups)];
check_setting(groups, undefined) ->
  [];

check_setting(Key, _) -> throw({bad_connection_settings, Key}).

%% +--------------------------------------------------------------+
%% |                           OTP API                            |
%% +--------------------------------------------------------------+

stop(#?MODULE{pid = PID}) ->
  exit(PID, shutdown);

stop(_) ->
  throw( bad_arg ).

%% +--------------------------------------------------------------+
%% |                   OTP gen_statem behaviour                   |
%% +--------------------------------------------------------------+

callback_mode() -> [
  handle_event_function,
  state_enter
].

init(#{owner := Owner } = Settings ) ->
  link( Owner ),
  {ok, ?WAIT_CONNECTION, Settings}.

%% +--------------------------------------------------------------+
%% |             Waiting for the connection request               |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, ?WAIT_CONNECTION, _Data) ->
  {keep_state_and_data, [{state_timeout, 0, timeout}]};

handle_event(state_timeout, timeout, ?WAIT_CONNECTION, #{
  owner      := Owner,
  server     := Server,
  settings   := #{ groups := Groups } = OwnSettings,
  connection := ConnectionSettings,
  transport  := TransportSettings,
  cache      := Cache
} = Settings) ->

  Connection = wait_connection(Server, ConnectionSettings, TransportSettings),

  unlink( Owner ),
  erlang:monitor(process, Owner),

  % Handle the listening socket to the next state machine
  case gen_statem:start(?MODULE, Settings, []) of
    {ok, _} -> ok;
    {error, Error}->
      ?LOGERROR("unable to create a new listening process, error ~p",[Error]),
      exit(Owner, Error)
  end,

  {next_state, ?WAIT_ACTIVATION, #data{
    owner = Owner,
    connection = Connection,
    settings = OwnSettings,
    cache = Cache,
    groups = Groups
  }};

%% +--------------------------------------------------------------+
%% |             Waiting for the activation               |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, ?WAIT_ACTIVATION, _Data) ->
  keep_state_and_data;

handle_event(info, ?DATA(Connection, start_dt_activate), ?WAIT_ACTIVATION, #data{
  connection = Connection,
  settings = #{name := Scope}
} = Data) ->

  iec60870_connection:cmd(Connection, start_dt_confirm),
  esubscribe:subscribe(Scope, update, self()),

  {next_state, ?RUNNING, Data};

% --------------------------------------------

handle_event(enter, _PrevState, ?RUNNING, _Data) ->
  keep_state_and_data;

% From esubscriber notify
handle_event(info, {Scope, update, {IOA, Value}, _Node, Actor}, ?RUNNING, #data{
  settings = #{name := Scope},
  connection = Connection
}) when Actor =/= self() ->
  iec60870_connection:cmd(Connection, {write_object, IOA, Value, spontaneous}),
  keep_state_and_data;

% Group request {object, Type, ValueCOT, Address, Value}
handle_event(info, ?DATA(Connection, ?OBJECT(?C_IC_NA_1, activation, _IOA, GroupID)), ?RUNNING, #data{
  connection = Connection,
  cache = Cache
}) ->

  iec60870_connection:cmd(Connection, {group_request_confirm, GroupID}),

  Items = find_group_items( GroupID, Cache ),

  [ iec60870_connection:cmd(Connection, {write_object, IOA, Value, {group, GroupID}}) || { IOA, Value } <- Items ],

  iec60870_connection:cmd(Connection, {group_request_terminate, GroupID}),

  keep_state_and_data;

% From the connection
handle_event(info, ?DATA(Connection, ?OBJECT(Type, _COT, IOA, Value)), ?RUNNING, #data{
  settings = #{name := Name},
  connection = Connection,
  cache = Cache
}) when is_map( Value )->

  update_value(Name, Cache, Type, IOA, Value),

  keep_state_and_data;

% Ignore self notifications
handle_event(info, {_Scope, update, _, _, _Self}, _AnyState, _Data) ->
  keep_state_and_data;

% The server is down
handle_event(info, {'DOWN', _, process, Owner, Error}, _AnyState, #data{
  owner = Owner
}) ->
  ?LOGINFO("stop server gen_statem, reason: ~p", [Error] ),
  {stop, Error};

% Log unexpected events
handle_event(EventType, EventContent, _AnyState, _Data) ->
  ?LOGWARNING("Server connection received unexpected event type ~p, content ~p", [
    EventType, EventContent
  ]),
  keep_state_and_data.

terminate(Reason, _, _State) when Reason=:=normal; Reason =:= shutdown->
  ?LOGDEBUG("incoming connection is terminated. Reason: ~p", [Reason]),
  ok;
terminate({connection_closed,Reason}, _, _State)->
  ?LOGDEBUG("incoming connection is closed. Reason: ~p", [Reason]),
  ok;
terminate(Reason, _, _Data) ->
  ?LOGWARNING("incoming connection is terminated. Reason: ~p", [Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% +--------------------------------------------------------------+
%% |             Internal helpers                                 |
%% +--------------------------------------------------------------+
wait_connection( Server, Connection, #{
  settings := Settings
} =Transport )->

  iec60870_connection:start_link(Connection, Transport#{
    settings =>Settings#{
      server => Server
    }
  }).

update_value(Scope, Cache, Type, IOA, InValue) when is_map( InValue )->

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
    ts => erlang:system_time(millisecond),
    qds => undefined
  }, InValue),

  ets:insert(Cache, {IOA, Value}),
  % Any updates notification
  esubscribe:notify(Scope, update, {IOA, Value}),
  % Only address notification
  esubscribe:notify(Scope, IOA, Value);

update_value(_Scope, _Cache, Type, IOA, InValue)->
  % TODO. We should handle this types in state machine states
  ?LOGWARNING("unexpected type message: type ~p, IOA ~p, Value ~p",[
    Type,
    IOA,
    InValue
  ]).

find_group_items( _GroupID = 0, Cache )->
  ets:tab2list( Cache );
find_group_items( GroupID, Cache )->
  ets:match_object(Cache, {'_',#{ group => GroupID }}).

