%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_lib).

-include("iec60870.hrl").

%%% +--------------------------------------------------------------+
%%% |                           API                                |
%%% +--------------------------------------------------------------+

-export([
  bytes_to_bits/1,
  get_driver_module/1,
  update_diagnostics/3
]).

%%% +--------------------------------------------------------------+
%%% |                      API Implementation                      |
%%% +--------------------------------------------------------------+

get_driver_module('104') -> iec60870_104;
get_driver_module('101') -> iec60870_101;
get_driver_module(Type)  -> throw({invalid_protocol_type, Type}).

bytes_to_bits(Bytes) -> Bytes * 8.

update_diagnostics(Diagnostics, TargetKey, {MapKey, MapValue}) ->
  case ets:lookup(Diagnostics, TargetKey) of
    [{TargetKey, OldMap}] ->
      UpdatedMap = OldMap#{MapKey => {MapValue, erlang:system_time(millisecond)}},
      ets:insert(Diagnostics, {TargetKey, UpdatedMap});
    [] ->
      NewMap = #{MapKey => {MapValue, erlang:system_time(millisecond)}},
      ets:insert(Diagnostics, {TargetKey, NewMap})
  end;
update_diagnostics(Diagnostics, TargetKey, MapKey) ->
  case ets:lookup(Diagnostics, TargetKey) of
    [{TargetKey, OldMap}] ->
      UpdatedMap = OldMap#{MapKey => erlang:system_time(millisecond)},
      ets:insert(Diagnostics, {TargetKey, UpdatedMap});
    [] ->
      NewMap = #{MapKey => erlang:system_time(millisecond)},
      ets:insert(Diagnostics, {TargetKey, NewMap})
  end.