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
  get_driver_module/1
]).

%%% +--------------------------------------------------------------+
%%% |                      API Implementation                      |
%%% +--------------------------------------------------------------+

get_driver_module('104') -> iec60870_104;
get_driver_module('101') -> iec60870_101;
get_driver_module(Type)  -> throw({invalid_protocol_type, Type}).

bytes_to_bits(Bytes) -> Bytes * 8.