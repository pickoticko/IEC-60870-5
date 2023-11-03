%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+

-ifndef(iec60870_asdu).
-define(iec60870_asdu, 1).

-record(asdu, {
  type,
  t,
  pn,
  cot,
  org,
  coa,
  objects
}).

-define(DEFAULT_ASDU_SETTINGS,#{
  coa => 1,
  org => 0,
  coa_size => 2,
  org_size => 1,
  ioa_size => 3
}).




%% Cause of transmission (COT) values
-define(COT_PER, 1).
-define(COT_BACK, 2).
-define(COT_SPONT, 3).
-define(COT_INIT, 4).
-define(COT_REQ, 5).
-define(COT_ACT, 6).
-define(COT_ACTCON, 7).
-define(COT_DEACT, 8).
-define(COT_DEACTCON, 9).
-define(COT_ACTTERM, 10).
-define(COT_RETREM, 11).
-define(COT_RETLOC, 12).
-define(COT_FILE, 13).
-define(COT_GROUP_MIN, 20).
-define(COT_GROUP_MAX, 36).
-define(COT_GROUP_COUNTER_MIN, 37).
-define(COT_GROUP(ID), ?COT_GROUP_MIN + ID).
-define(COT_GROUP_COUNTER_MAX, 41).
-define(COT_UNKNOWN_TYPE, 44).
-define(COT_UNKNOWN_CAUSE, 45).
-define(COT_UNKNOWN_ASDU_ADDRESS, 46).
-define(COT_UNKNOWN_OBJECT_ADDRESS, 47).

-endif.