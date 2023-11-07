%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+

-module(iec60870_client).

-include("iec60870.hrl").
-include("asdu.hrl").

-define(REQUIRED,{?MODULE, required}).

-define(DEFAULT_SETTINGS, maps:merge( #{
  name => ?REQUIRED,
  type => ?REQUIRED,
  connection => ?REQUIRED,
  groups => []
}, ?DEFAULT_ASDU_SETTINGS )).


-record(?MODULE, {
  storage,
  pid,
  name
}).

%%-----------------------------------------------------------------
%%  API
%%-----------------------------------------------------------------
-export([
  start/1,
  stop/1,
  write/3,
  read/1, read/2,
  subscribe/3, subscribe/2,
  unsubscribe/3, unsubscribe/2,
  get_pid/1
]).

%%-----------------------------------------------------------------
%%  Cross module API
%%-----------------------------------------------------------------
-export([
  find_group_items/2
]).

%% +--------------------------------------------------------------+
%% |                              API                             |
%% +--------------------------------------------------------------+
start( InSettings ) ->
  #{
    name := Name
  } = Settings = check_settings(InSettings),

  PID =
    case gen_statem:start_link(iec60870_client, {_OwnerPID = self(), Settings}, []) of
      {ok, _PID} -> _PID;
      {error, Error} -> throw(Error)
    end,
  receive
    {ready, PID, Storage}  -> #?MODULE{
      pid = PID,
      name = Name,
      storage = Storage
    };
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

stop(#?MODULE{pid = PID}) ->
  gen_statem:stop(PID);
stop(_) ->
  throw( bad_arg ).

read( Ref ) ->
  find_group_items(Ref, 0).

read(#?MODULE{storage = Storage}, ID) ->
  case ets:lookup(Storage, ID) of
    [] -> undefined;
    [{ID, Value}] -> Value
  end;
read(_, _) ->
  throw( bad_arg ).

write(#?MODULE{pid = PID}, IOA, Value) ->
  PID ! {write, IOA, Value},
  ok.

subscribe(#?MODULE{name = Name}, PID) when is_pid(PID) ->
    esubscribe:subscribe(Name, update, PID);
subscribe(_, _) ->
  throw( bad_arg ).

subscribe(#?MODULE{name = Name}, PID, AddressList) when is_pid(PID), is_list(AddressList) ->
  [begin
     esubscribe:subscribe(Name, Address, PID)
   end || Address <- AddressList],
  ok;

subscribe(#?MODULE{name = Name}, PID, Address) when is_pid(PID) ->
    esubscribe:subscribe(Name, Address, PID);
subscribe(_, _, _) ->
  throw( bad_arg ).

unsubscribe(#?MODULE{name = Name}, PID, AddressList) when is_list( AddressList ), is_pid(PID) ->
  [begin
     esubscribe:unsubscribe(Name, Address, PID)
   end || Address <- AddressList],
  ok;
unsubscribe(#?MODULE{name = Name}, PID, Address) when is_pid(PID) ->
    esubscribe:unsubscribe(Name, Address, PID);
unsubscribe(_, _, _) ->
  throw( bad_arg ).

unsubscribe(Ref, PID) when is_pid( PID )->
  AddressList = [ A || {A, _} <- read( Ref ) ],
  unsubscribe( Ref, AddressList );
unsubscribe(_, _) ->
  throw( bad_arg ).

get_pid(#?MODULE{pid = PID}) ->
  PID;
get_pid(_) ->
  throw( bad_arg ).

%%-----------------------------------------------------------------
%%  Cross module API
%%-----------------------------------------------------------------
find_group_items(#?MODULE{ storage = Storage }, _GroupID = 0 )->
  ets:tab2list( Storage );
find_group_items(#?MODULE{ storage = Storage }, GroupID )->
  ets:match_object(Storage, {'_',#{ group => GroupID }}).



%% +--------------------------------------------------------------+
%% |                      Internal functions                      |
%% +--------------------------------------------------------------+

check_settings( Settings ) when is_map( Settings ) ->
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
  );
check_settings(_) ->
  throw(invalid_settings).


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
         update => undefined,
         timeout => undefined
       };
     _ ->
       throw({bad_group_settings, Group})
   end || Group <- lists:uniq(Groups)];
check_setting(groups, undefined) ->
  [];
check_setting(Key, _) ->
  throw({invalid_settings, Key}).

