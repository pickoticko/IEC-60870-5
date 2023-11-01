%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_lib).

-include("iec60870.hrl").

-export([
  bytes_to_bits/1,
  check_required_settings/2,
  get_binary_cot/2,
  get_driver_module/1,
  read_data_object/2,
  save_data_object/2
]).

get_driver_module('104') -> iec60870_tcp;
get_driver_module('101') -> iec60870_serial;
get_driver_module(Type)  -> throw({invalid_type, Type}).

bytes_to_bits(Bytes) -> Bytes * 8.

check_required_settings(Settings, RequiredList) ->
  [case maps:is_key(Key, Settings) of
     true -> ok;
     _ -> throw({required_field, Key})
   end || Key <- RequiredList],
  ok.

read_data_object(TableReference, Key) when is_reference(TableReference) ->
  case ets:lookup(TableReference, Key) of
    [] -> undefined;
    [{Key, Value}] -> Value
  end;
read_data_object(_, _) -> bad_arg.

save_data_object(TableReference, DataObject) when is_tuple(DataObject) ->
  {Key, Value} = DataObject,
  ets:insert(TableReference, {Key, Value}),
  ok;
save_data_object(_, _) -> bad_arg.

get_binary_cot(StringCOT, COTByteSize) ->
  if
    StringCOT =:= <<"cycle">>, COTByteSize =:= 2 ->
      <<16#01:8, 16#00:8>>;
    StringCOT =:= <<"cycle">>, COTByteSize =:= 1 ->
      <<16#1:8>>;
    StringCOT =/= <<"cycle">>, COTByteSize =:= 2 ->
      <<16#03:8, 16#00:8>>;
    StringCOT =/= <<"cycle">>, COTByteSize =:= 1 ->
      <<16#03:8>>
  end.