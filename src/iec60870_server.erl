%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_server).

-include("iec60870.hrl").
-include("asdu.hrl").

%% +--------------------------------------------------------------+
%% |                           External API                       |
%% +--------------------------------------------------------------+
-export([
  start/1,
  stop/1,
  write/3,
  read/1, read/2,
  get_pid/1
]).

%% +--------------------------------------------------------------+
%% |                           Cross module API                   |
%% +--------------------------------------------------------------+
-export([
  start_connection/3,
  find_group_items/2,
  update_value/3
]).


-record(?MODULE, {
  storage,
  pid,
  name
}).

-record(state,{
  server,
  module,
  connection_settings
}).


%%  #{
%%
%%    name => some_atom,
%%    groups => [],
%%    coa => 1,
%%    org => 0,
%%    coa_size => 2,
%%    org_size => 1,
%%    ioa_size => 3,
%%
%%    % -----------101-----------------------------
%%    type => '101',
%%    connection => #{
%%      port => "/dev/ttyUSB0",
%%      balanced => false,
%%      port_options =>#{
%%        baudrate => 9600,
%%        parity => 0,
%%        stopbits => 1,
%%        bytesize => 8
%%      },
%%      address => 1,
%%      address_size => 1
%%    },
%%
%%    % -----------104-----------------------------
%%    type => '104',
%%    connection => #{
%%      port => 4000,
%%      t1 => 5000,
%%      t2 => 10000,
%%      t3 => infinity,
%%      k => 12,
%%      w => 8
%%    }
%%
%%  }

-define(REQUIRED,{?MODULE, required}).

-define(DEFAULT_SETTINGS,maps:merge( #{
  name => ?REQUIRED,
  type => ?REQUIRED,
  connection => ?REQUIRED,
  groups => []
}, ?DEFAULT_ASDU_SETTINGS )).


start(InSettings) ->

  Settings = check_settings( maps:merge(?DEFAULT_SETTINGS, InSettings) ),

  Self = self(),
  PID = spawn_link(fun()->init_server(Self, Settings) end),
  receive
    {ready, PID, ServerRef}  ->
      unlink( PID ),
      ServerRef;
    {'EXIT', PID, Reason} ->
      throw(Reason)
  end.

stop(#?MODULE{pid = PID}) ->
  exit(PID, shutdown);

stop(_) ->
  throw( bad_arg ).

% API
get_pid(#?MODULE{pid = PID}) -> PID.

write(Ref, ID, Value )->
  update_value( Ref, ID, Value ).

read(#?MODULE{} = Ref) ->
  find_group_items(Ref, 0);
read(_) -> throw(bad_arg).

read(#?MODULE{storage = Cache}, Address) ->
  iec60870_lib:read_data_object(Cache, Address);
read(_, _) -> throw(bad_arg).

find_group_items(#?MODULE{ storage = Storage }, _GroupID = 0 )->
  ets:tab2list( Storage );
find_group_items(#?MODULE{ storage = Storage }, GroupID )->
  ets:match_object(Storage, {'_',#{ group => GroupID }}).


%% +--------------------------------------------------------------+
%% |                           Cross module API                   |
%% +--------------------------------------------------------------+
start_connection(Root, Server, Connection )->
  Root ! {start_connection, Server, self(), Connection },
  receive
    {Root, PID} when is_pid( PID )-> {ok, PID};
    {Root, error}-> error
  end.

update_value( #?MODULE{ name = Name, storage = Storage }, ID, InValue)->
  Group =
    case InValue of
      #{ group := _G } when is_number( _G )-> _G;
      _->
        case ets:lookup( Storage, ID ) of
          [{_, #{ group :=_G }}] -> _G;
          _-> undefined
        end
    end,

  Value = maps:merge(#{
    group => Group,
    type => undefined,
    value => undefined,
    ts => erlang:system_time(millisecond),
    qds => undefined
  }, InValue),

  ets:insert(Storage, {ID, Value}),
  % Any updates notification
  esubscribe:notify(Name, update, {ID, Value}),
  % Only address notification
  esubscribe:notify(Name, ID, Value).


%% +--------------------------------------------------------------+
%% |                           Internal stuff                     |
%% +--------------------------------------------------------------+
check_settings( Settings )->
  SettingsList = maps:to_list( Settings ),

  case [S || {S, ?REQUIRED} <- SettingsList] of
    [] -> ok;
    Required -> throw( {required, Required} )
  end,

  case maps:keys( Settings ) -- maps:keys(?DEFAULT_SETTINGS) of
    []-> ok;
    InvalidParams -> throw( {invalid_params, InvalidParams} )
  end,

  OwnSettings = maps:without(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings),
  maps:merge(
    maps:map(fun check_setting/2, OwnSettings ),
    maps:with( maps:keys(?DEFAULT_ASDU_SETTINGS), Settings )
  ).


check_setting(name, ConnectionName)
  when is_atom(ConnectionName) -> ConnectionName;

check_setting(type, Type)
  when Type =:= '101'; Type =:= '104' -> Type;

check_setting(connection, Settings)
  when is_map(Settings) -> Settings;

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
  [].



init_server(Owner, #{
  name := Name,
  type := Type,
  connection := Connection
} = Settings )->

  process_flag(trap_exit, true),

  Module = iec60870_lib:get_driver_module( Type ),

  Server = Module:start_server(_Root = self(), Connection ),

  Storage = ets:new(data_objects, [
    set,
    public,
    {read_concurrency, true},
    {write_concurrency, auto}
  ]),

  case esubscribe:start_link( Name ) of
    {ok, _PID} -> ok;
    {error, Reason} -> throw(Reason)
  end,

  Ref = #?MODULE{
    pid = self(),
    storage = Storage,
    name = Name
  },

  ConnectionSettings = #{
    name => Name,
    storage => Storage,
    root => Ref,
    groups => maps:get( groups, Settings ),
    asdu => iec60870_asdu:get_settings( maps:with(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings))
  },

  Owner ! {ready, self(), Ref},

  wait_connection(#state{
    module = Module,
    server = Server,
    connection_settings = ConnectionSettings
  }).

wait_connection( #state{
  module = Module,
  server = Server,
  connection_settings = ConnectionSettings
} = State)->
  receive
    {start_connection, Server, From, Connection } ->
      case gen_statem:start(iec60870_server_stm, {Connection, ConnectionSettings}, []) of
        {ok, PID} ->
          From ! {self(), PID};
        {error, Error}->
          ?LOGERROR("unable to start process for incomung connection, error ~p",[Error]),
          From ! {self(), error}
      end,
      wait_connection( State );
    {'EXIT' ,_, StopReason}->
      ?LOGINFO("stop server, reason: ~p", [StopReason] ),
      Module:stop_server( Server ),
      exit(StopReason);
    Unexpected ->
      ?LOGWARNING( "unexpected mesaage ~p", [ Unexpected] ),
      wait_connection( State )
  end.



