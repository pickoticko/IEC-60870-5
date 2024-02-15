%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_lib).

-include("iec60870.hrl").

-export([
  bytes_to_bits/1,
  get_driver_module/1,
  read_data_object/2,
  save_data_object/2
]).

get_driver_module('104') -> iec60870_104;
get_driver_module('101') -> iec60870_101;
get_driver_module(Type)  -> throw({invalid_protocol_type, Type}).

bytes_to_bits(Bytes) -> Bytes * 8.

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