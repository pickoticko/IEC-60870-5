%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_lib).

-include("iec60870.hrl").

-export([
  bytes_to_bits/1,
  get_driver_module/1,
  try_register/2
]).

get_driver_module('104') -> iec60870_104;
get_driver_module('101') -> iec60870_101;
get_driver_module(Type)  -> throw({invalid_protocol_type, Type}).

bytes_to_bits(Bytes) -> Bytes * 8.

try_register(Atom, PID) ->
  try
    erlang:register(Atom, PID),
    ok
  catch
    _Exception:_Error ->
      {error, failed}
  end.