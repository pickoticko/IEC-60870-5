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

%% Function codes of unbalanced transmission from PRIMARY to SECONDARY
-define(RESET_REMOTE_LINK, 0).
-define(RESET_USER_PROCESS, 1).
-define(USER_DATA_CONFIRM, 3).
-define(USER_DATA_NO_REPLY, 4).
-define(ACCESS_DEMAND, 8).
-define(REQUEST_STATUS_LINK, 9).
-define(REQUEST_DATA_CLASS_1, 10).
-define(REQUEST_DATA_CLASS_2, 11).

%% Function codes of unbalanced transmission from SECONDARY to PRIMARY
-define(ACKNOWLEDGE, 0).
-define(NACK_LINK_BUSY, 1).
-define(USER_DATA, 8).
-define(NACK_DATA_NOT_AVAILABLE, 9).
-define(STATUS_LINK_ACCESS_DEMAND, 11).
-define(ERR_NOT_FUNCTIONING, 14).
-define(ERR_NOT_IMPLEMENTED, 15).

-endif.