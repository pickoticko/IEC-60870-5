-module(iec60870_client).

-include("iec60870.hrl").
-include("asdu.hrl").

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

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

-export([
  start/1,
  stop/1,
  write/3,
  read/1, read/2,
  subscribe/3, subscribe/2,
  unsubscribe/3, unsubscribe/2,
  get_pid/1
]).

%% +--------------------------------------------------------------+
%% |                       Cross Module API                       |
%% +--------------------------------------------------------------+

-export([
  find_group_items/2
]).

%% +--------------------------------------------------------------+
%% |                              API                             |
%% +--------------------------------------------------------------+

start(InSettings) ->
  #{name := Name} = Settings = check_settings(InSettings),
  PID =
    case gen_statem:start_link(iec60870_client_stm, {_OwnerPID = self(), Settings}, []) of
      {ok, _PID} -> _PID;
      {error, Error} -> throw(Error)
    end,
  receive
    {ready, PID, Storage} -> #?MODULE{
      pid = PID,
      name = Name,
      storage = Storage
    };
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

stop(#?MODULE{pid = PID}) ->
  gen_statem:stop(PID);
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

write(#?MODULE{pid = PID}, IOA, Value) ->
  case is_remote_command(Value) of
    true -> gen_statem:call(PID, {write, IOA, Value});
    false -> PID ! {write, IOA, Value}
  end,
  ok.

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

%% +--------------------------------------------------------------+
%% |                       Cross Module API                       |
%% +--------------------------------------------------------------+

find_group_items(#?MODULE{storage = Storage}, _GroupID = 0) ->
  ets:tab2list(Storage);

find_group_items(#?MODULE{storage = Storage}, GroupID) ->
  ets:match_object(Storage, {'_', #{group => GroupID}}).

%% +--------------------------------------------------------------+
%% |                      Internal functions                      |
%% +--------------------------------------------------------------+

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

is_remote_command(#{type := Type})
  when Type >= ?C_SC_NA_1, Type =< ?C_BO_NA_1;
       Type >= ?C_SC_TA_1, Type =< ?C_BO_TA_1 -> true;
is_remote_command(_Type) -> false.