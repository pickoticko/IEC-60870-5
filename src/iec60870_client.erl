%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_client).

-include("iec60870.hrl").
-include("asdu.hrl").

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(REQUIRED, {?MODULE, required}).

-define(DEFAULT_SETTINGS, maps:merge(#{
  name => ?REQUIRED,
  type => ?REQUIRED,
  connection => ?REQUIRED,
  groups => []
}, ?DEFAULT_ASDU_SETTINGS)).

-record(?MODULE, {
  storage,
  pid,
  name
}).

%%% +--------------------------------------------------------------+
%%% |                          Client API                          |
%%% +--------------------------------------------------------------+

-export([
  start/1,
  stop/1,
  write/3,
  read/1, read/2,
  subscribe/3, subscribe/2,
  unsubscribe/3, unsubscribe/2,
  get_pid/1
]).

%%% +---------------------------------------------------------------+
%%% |                        Cross Module API                       |
%%% +---------------------------------------------------------------+

-export([
  find_group_items/2
]).

%%% +---------------------------------------------------------------+
%%% |                   Client API Implementation                   |
%%% +---------------------------------------------------------------+

start(InSettings) ->
  #{name := Name} = Settings = check_settings(InSettings),
  OldFlag = process_flag(trap_exit, true),
  PID =
    case gen_statem:start_link(iec60870_client_stm, {_OwnerPID = self(), Settings}, []) of
      {ok, _PID} -> _PID;
      {error, Error} -> throw(Error)
    end,
  receive
    {ready, PID, Storage} ->
      process_flag(trap_exit, OldFlag),
      #?MODULE{
        pid = PID,
        name = Name,
        storage = Storage
      };
    {'EXIT', PID, Reason} ->
      process_flag(trap_exit, OldFlag),
      throw(Reason)
  end.

stop(#?MODULE{pid = PID}) ->
  case is_process_alive(PID) of
    true -> gen_statem:stop(PID);
    false -> ok
  end;
stop(_) ->
  throw(bad_arg).

read(Reference) ->
  find_group_items(Reference, 0).
read(#?MODULE{storage = Storage}, ID) ->
  case ets:lookup(Storage, ID) of
    [] -> undefined;
    [{ID, Value}] -> Value
  end;
read(_, _) ->
  throw(bad_arg).

write(#?MODULE{pid = PID}, IOA, InDataObject) when is_map(InDataObject) ->
  case is_process_alive(PID) of
    true ->
      OutDataObject = check_value(InDataObject),
      case is_remote_command(OutDataObject) of
        true ->
          %% This call returns 'ok' either {error, Reason}.
          case gen_statem:call(PID, {write, IOA, OutDataObject}) of
            ok ->
              ok;
            {error, Reason} ->
              ?LOGERROR("write operation call failed with reason: ~p", [Reason]),
              throw(Reason)
          end;
        false ->
          PID ! {write, IOA, OutDataObject},
          ok
      end;
    false ->
      ?LOGERROR("write operation called on no longer alive connection"),
      throw(connection_closed)
  end;
write(_, _, _) ->
  throw(bad_arg).

subscribe(#?MODULE{name = Name}, PID) when is_pid(PID) ->
    esubscribe:subscribe(Name, update, PID);
subscribe(_, _) ->
  throw(bad_arg).

subscribe(#?MODULE{name = Name}, PID, AddressList) when is_pid(PID), is_list(AddressList) ->
  [begin
     esubscribe:subscribe(Name, Address, PID)
   end || Address <- AddressList],
  ok;
subscribe(#?MODULE{name = Name}, PID, Address) when is_pid(PID) ->
    esubscribe:subscribe(Name, Address, PID);
subscribe(_, _, _) ->
  throw(bad_arg).

unsubscribe(#?MODULE{name = Name}, PID, AddressList) when is_list(AddressList), is_pid(PID) ->
  [begin
     esubscribe:unsubscribe(Name, Address, PID)
   end || Address <- AddressList],
  ok;
unsubscribe(#?MODULE{name = Name}, PID, Address) when is_pid(PID) ->
    esubscribe:unsubscribe(Name, Address, PID);
unsubscribe(_, _, _) ->
  throw(bad_arg).

unsubscribe(Reference, PID) when is_pid(PID) ->
  AddressList = [Address || {Address, _} <- read(Reference)],
  unsubscribe(Reference, AddressList);
unsubscribe(_, _) ->
  throw(bad_arg).

get_pid(#?MODULE{pid = PID}) ->
  PID;
get_pid(_) ->
  throw(bad_arg).

%% +---------------------------------------------------------------+
%% |               Cross Module API Implementation                 |
%% +---------------------------------------------------------------+

find_group_items(#?MODULE{storage = Storage}, _GroupID = 0) ->
  ets:tab2list(Storage);

find_group_items(#?MODULE{storage = Storage}, GroupID) ->
  ets:match_object(Storage, {'_', #{group => GroupID}}).

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

check_settings(Settings) when is_map(Settings) ->
  SettingsList = maps:to_list(Settings),
  case [S || {S, ?REQUIRED} <- SettingsList] of
    [] -> ok;
    Required -> throw( {required, Required} )
  end,
  case maps:keys(Settings) -- maps:keys(?DEFAULT_SETTINGS) of
    [] -> ok;
    InvalidParams -> throw({invalid_params, InvalidParams})
  end,
  OwnSettings = maps:without(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings),
  maps:merge(
    maps:map(fun check_setting/2, OwnSettings),
    maps:with(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings)
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

is_remote_command(#{type := Type})->
  (Type >= ?C_SC_NA_1 andalso Type =< ?C_BO_NA_1) orelse
  (Type >= ?C_SC_TA_1 andalso Type =< ?C_BO_TA_1).

%% The object data must contain a 'value' key
check_value(#{value := Value} = ObjectData) when is_number(Value) ->
  ObjectData;
%% If an object's value is undefined, then we set its value
%% to 0 and enable the quality bit for invalid values
check_value(#{value := none} = ObjectData) ->
  ObjectData#{value => 0};
check_value(#{value := undefined} = ObjectData) ->
  ObjectData#{value => 0};
%% Key 'value' is missing, incorrect object passed
check_value(_Value) ->
  throw({error, value_parameter_missing}).