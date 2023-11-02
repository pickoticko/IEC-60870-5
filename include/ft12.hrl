%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-ifndef(iec60870_f12).
-define(iec608701_ft12, 1).

-record(cf_req,{
  dir,
  fcb,
  fcv,
  fcode
}).

-record(cf_resp,{
  dir,
  acd,
  dfc,
  fcode
}).

-record(frame,{
  addr,
  cf,
  data
}).

-endif.