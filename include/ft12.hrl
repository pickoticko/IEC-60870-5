%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+

-ifndef(iec60870_ft12).
-define(iec608701_ft12, 1).

-record(control_field_request, {
  direction = 0,
  fcb,
  fcv,
  function_code
}).

-record(control_field_response, {
  direction,
  acd,
  dfc,
  function_code
}).

-record(frame, {
  address,
  control_field,
  data
}).

-endif.