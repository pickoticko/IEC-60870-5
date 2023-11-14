%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+

-module(iec60870_type).

-include("iec60870.hrl").
-include("asdu.hrl").

-export([
  parse_information_element/2,
  create_information_element/2
]).

-define(UNIX_EPOCH_DATE, {1970, 1, 1}).

%% +--------------------------------------------------------------+
%% |                           Parsing                            |
%% +--------------------------------------------------------------+

%% Type 1. Single point information
parse_information_element(?M_SP_NA_1, <<SIQ>>) ->
  <<_Ignore:7, SPI:1>> = <<SIQ>>,
  #{value => SPI, siq => SIQ};

%% Type 2. Single point information with time tag
parse_information_element(?M_SP_TA_1, <<SIQ, Timestamp/binary>>) ->
  <<_Ignore:7, SPI:1>> = <<SIQ>>,
  #{value => SPI, siq => SIQ, ts => parse_cp24(Timestamp)};

%% Type 3. Double point information
parse_information_element(?M_DP_NA_1, <<DIQ>>) ->
  <<_Ignore:6, DPI:2>> = <<DIQ>>,
  #{value => DPI, diq => DIQ};

%% Type 4. Double point information with time tag
parse_information_element(?M_DP_TA_1, <<DIQ, Timestamp/binary>>) ->
  <<_Ignore:6, DPI:2>> = <<DIQ>>,
  #{value => DPI, diq => DIQ, ts => parse_cp24(Timestamp)};

%% Type 5. Step position information
parse_information_element(?M_ST_NA_1, <<VTI, QDS>>) ->
  <<_Ignore:1, Value:7/signed>> = <<VTI>>,
  #{value => Value, vti => VTI, qds => QDS};

%% Type 6. Step position information with time tag
parse_information_element(?M_ST_TA_1, <<VTI, QDS, Timestamp/binary>>) ->
  <<_Ignore:1, Value:7/signed>> = <<VTI>>,
  #{value => Value, vti => VTI, qds => QDS, ts => parse_cp24(Timestamp)};

%% Type 7. Bit string of 32 bit
parse_information_element(?M_BO_NA_1, <<BSI:32/little-unsigned, QDS>>) ->
  #{value => BSI, qds => QDS};

%% Type 8. Bit string of 32 bit with time tag
parse_information_element(?M_BO_TA_1, <<BSI:32/little-unsigned, QDS, Timestamp/binary>>) ->
  #{value => BSI, qds => QDS, ts => parse_cp24(Timestamp)};

%% Type 9. Measured value, normalized value
parse_information_element(?M_ME_NA_1, <<NVA:16/little-signed-float, QDS>>) ->
  #{value => NVA, qds => QDS};

%% Type 10. Measured value, normalized value with time tag
parse_information_element(?M_ME_TA_1, <<NVA:16/little-signed-float, QDS, Timestamp/binary>>) ->
  #{value => NVA, qds => QDS, ts => parse_cp24(Timestamp)};

%% Type 11. Measured value, scaled value
parse_information_element(?M_ME_NB_1, <<SVA:16/little-signed, QDS>>) ->
  #{value => SVA, qds => QDS};

%% Type 12. Measured value, scaled value with time tag
parse_information_element(?M_ME_TB_1, <<SVA:16/little-signed, QDS, Timestamp/binary>>) ->
  #{value => SVA, qds => QDS, ts => parse_cp24(Timestamp)};

%% Type 13. Measured value, short floating point
parse_information_element(?M_ME_NC_1, <<Value:32/little-signed-float, QDS>>) ->
  #{value => Value, qds => QDS};

%% Type 14. Measured value, short floating point with time tag
parse_information_element(?M_ME_TC_1, <<Value:32/little-signed-float, QDS, Timestamp/binary>>) ->
  #{value => Value, qds => QDS, ts => parse_cp24(Timestamp)};

%% Type 15. Integrated totals
parse_information_element(?M_IT_NA_1, <<BCR:40>>) ->
  <<Value:32/little-signed, _Ignore:8>> = <<BCR:40>>,
  #{value => Value, bcr => BCR};

%% Type 16. Integrated totals with time tag
parse_information_element(?M_IT_TA_1, <<BCR:40, Timestamp/binary>>) ->
  <<Value:32/little-signed, _Ignore:8>> = <<BCR:40>>,
  #{value => Value, bcr => BCR, ts => parse_cp24(Timestamp)};

%% Type 17. Protection equipment with time tag
parse_information_element(?M_EP_TA_1, <<SEP, CP16:16, Timestamp/binary>>) ->
  <<_Ignore:6, ES:2>> = <<SEP>>,
  #{value => ES, sep => SEP, duration => parse_cp16(CP16), ts => parse_cp24(Timestamp)};

%% Type 18. Packed events of protection equipment with time tag
parse_information_element(?M_EP_TB_1, <<SPE, QDP, Timestamp16:16, Timestamp24/binary>>) ->
  #{value => SPE, qdp => QDP, duration => parse_cp16(Timestamp16), ts => parse_cp24(Timestamp24)};

%% Type 19. Packed output circuit information of protection equipment with time tag
parse_information_element(?M_EP_TC_1, <<OCI, QDP, Timestamp16:16, Timestamp24/binary>>) ->
  #{value => OCI, qdp => QDP, duration => parse_cp16(Timestamp16), ts => parse_cp24(Timestamp24)};

%% Type 20. Packed single-point information with status change detection
parse_information_element(?M_PS_NA_1, <<SCD:32/little, QDS>>) ->
  #{value => SCD, qds => QDS};

%% Type 21. Measured value, normalized value without QDS
parse_information_element(?M_ME_ND_1, <<NVA:16/little-signed-float>>) ->
  #{value => NVA};

%% Type 30. Single point information with time tag
parse_information_element(?M_SP_TB_1, <<SIQ, Timestamp/binary>>) ->
  <<_Ignore:7, SPI:1>> = <<SIQ>>,
  #{value => SPI, qds => SIQ, ts => parse_cp56(Timestamp)};

%% Type 31. Double point information with time tag
parse_information_element(?M_DP_TB_1, <<DIQ, Timestamp/binary>>) ->
  <<_Ignore:6, DPI:2>> = <<DIQ>>,
  #{value => DPI, qds => DIQ, ts => parse_cp56(Timestamp)};

%% Type 32. Step position information with time tag
parse_information_element(?M_ST_TB_1, <<VTI, QDS, Timestamp/binary>>) ->
  <<_Ignore:1, Value:7/signed>> = <<VTI>>,
  #{value => Value, vti => VTI, qds => QDS, ts => parse_cp56(Timestamp)};

%% Type 33. Bit string of 32 bit with time tag
parse_information_element(?M_BO_TB_1, <<BSI:32/little-unsigned, QDS, Timestamp/binary>>) ->
  #{value => BSI, qds => QDS, ts => parse_cp56(Timestamp)};

%% Type 34. Measured value, normalized value with time tag
parse_information_element(?M_ME_TD_1, <<NVA:16/little-signed-float, QDS, Timestamp/binary>>) ->
  #{value => NVA, qds => QDS, ts => parse_cp56(Timestamp)};

%% Type 35. Measured value, scaled value with time tag
parse_information_element(?M_ME_TE_1, <<SVA:16/little-signed, QDS, Timestamp/binary>>) ->
  #{value => SVA, qds => QDS, ts => parse_cp56(Timestamp)};

%% Type 36. Measured value, short floating point value with time tag
parse_information_element(?M_ME_TF_1, <<Value:32/little-signed-float, QDS, Timestamp/binary>>) ->
  #{value => Value, qds => QDS, ts => parse_cp56(Timestamp)};

%% Type 37. Integrated totals with time tag
parse_information_element(?M_IT_TB_1, <<BCR:40, Timestamp/binary>>) ->
  <<Value:32/little-signed, _Ignore:8>> = <<BCR:40>>,
  #{value => Value, bcr => BCR, ts => parse_cp56(Timestamp)};

%% Type 38. Event of protection equipment with time tag
parse_information_element(?M_EP_TD_1, <<SEP, Interval:16/little-unsigned, Timestamp/binary>>) ->
  <<_Ignore:6, ES:2>> = <<SEP>>,
  #{value => ES, sep => SEP, interval => Interval, ts => parse_cp56(Timestamp)};

%% Type 70. End of initialization
parse_information_element(?M_EI_NA_1, <<COI>>) ->
  <<_Ignore:1, Value:7>> = <<COI>>,
  #{value => Value, coi => COI};

%% Type 100. Group request
parse_information_element(?C_IC_NA_1, <<GroupID>>) ->
  GroupID - ?COT_GROUP_MIN;

%% Type 101. Group counter request
parse_information_element(?C_CI_NA_1, <<GroupCounterID>>) ->
  GroupCounterID - ?COT_GROUP_COUNTER_MIN;

%% Type 103. Clock synchronization
parse_information_element(?C_CS_NA_1, Timestamp) ->
  parse_cp56(Timestamp);

parse_information_element(Type, Value) ->
  throw({invalid_type_or_value, Type, Value}).

%% +--------------------------------------------------------------+
%% |                          Creating                            |
%% +--------------------------------------------------------------+

%% Type 1. Single point information
create_information_element(?M_SP_NA_1, #{
  value := SPI,
  siq := SIQ
}) ->
  <<Rest:7, _Ignore:1>> = <<SIQ>>,
  <<Rest:7, SPI>>;

%% Type 2. Single point information with time tag
create_information_element(?M_SP_TA_1, #{
  value := SPI,
  siq := SIQ,
  ts := Timestamp
}) ->
  <<Rest:7, _Ignore:1>> = <<SIQ>>,
  <<Rest:7, SPI:1, (get_cp24(Timestamp))/binary>>;

%% Type 3. Double point information
create_information_element(?M_DP_NA_1, #{
  value := DPI,
  diq := DIQ
}) ->
  <<Rest:6, _Ignore:2>> = <<DIQ>>,
  <<Rest:6, DPI:2>>;

%% Type 4. Double point information with time tag
create_information_element(?M_DP_TA_1, #{
  value := DPI,
  diq := DIQ,
  ts := Timestamp
}) ->
  <<Rest:6, _Ignore:2>> = <<DIQ>>,
  <<Rest:6, DPI:2, (get_cp24(Timestamp))/binary>>;

%% Type 5. Step position information
create_information_element(?M_ST_NA_1, #{
  value := Value,
  vti := VTI,
  qds := QDS
}) ->
  <<State:1, _Ignore:7>> = <<VTI>>,
  <<State:1, Value:7/signed, QDS>>;

%% Type 6. Step position information with time tag
create_information_element(?M_ST_TA_1, #{
  value := Value,
  vti := VTI,
  qds := QDS,
  ts := Timestamp
}) ->
  <<State:1, _Ignore:7>> = <<VTI>>,
  <<State:1, Value:7/signed, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 7. Bit string of 32 bit
create_information_element(?M_BO_NA_1, #{
  value := BSI,
  qds := QDS
}) ->
  <<BSI:32/little-unsigned, QDS>>;

%% Type 8. Bit string of 32 bit with time tag
create_information_element(?M_BO_TA_1, #{
  value := BSI,
  qds := QDS,
  ts := Timestamp
}) ->
  <<BSI:32/little-unsigned, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 9. Measured value, normalized value
create_information_element(?M_ME_NA_1, #{
  value := NVA,
  qds := QDS
}) ->
  <<NVA:16/little-signed-float, QDS>>;

%% Type 10. Measured value, normalized value with time tag
create_information_element(?M_ME_TA_1, #{
  value := NVA,
  qds := QDS,
  ts := Timestamp
}) ->
  <<NVA:16/little-signed-float, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 11. Measured value, scaled value
create_information_element(?M_ME_NB_1, #{
  value := SVA,
  qds := QDS
}) ->
  <<SVA:16/little-signed, QDS>>;

%% Type 12. Measured value, scaled value with time tag
create_information_element(?M_ME_TB_1, #{
  value := SVA,
  qds := QDS,
  ts := Timestamp
}) ->
  <<SVA:16/little-signed, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 13. Measured value, short floating point
create_information_element(?M_ME_NC_1, #{
  value := Value,
  qds := QDS
}) ->
  <<Value:32/little-signed-float, QDS>>;

%% Type 14. Measured value, short floating point with time tag
create_information_element(?M_ME_TC_1, #{
  value := Value,
  qds := QDS,
  ts := Timestamp
}) ->
  <<Value:32/little-signed-float, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 15. Integrated totals
create_information_element(?M_IT_NA_1, #{
  value := Value,
  bcr := BCR
}) ->
  <<_Ignore:32, Rest>> = <<BCR:40>>,
  <<Value:32/little-signed, Rest>>;

%% Type 16. Integrated totals with time tag
create_information_element(?M_IT_TA_1, #{
  value := Value,
  bcr := BCR,
  ts := Timestamp
}) ->
  <<_Ignore:32, Rest>> = <<BCR:40>>,
  <<Value:32/little-signed, Rest, (get_cp24(Timestamp))/binary>>;

%% Type 17. Protection equipment with time tag
create_information_element(?M_EP_TA_1, #{
  value := ES,
  sep := SEP,
  duration := Duration,
  ts := Timestamp
}) ->
  <<Rest:6, _Ignore:2>> = <<SEP>>,
  <<Rest:6, ES:2, (get_cp16(Duration)):16/binary, (get_cp24(Timestamp))/binary>>;

%% Type 18. Packed events of protection equipment with time tag
create_information_element(?M_EP_TB_1, #{
  value := SPE,
  qdp := QDP,
  duration := Duration,
  ts := Timestamp
}) ->
  <<SPE, QDP, (get_cp16(Duration)):16/binary, (get_cp24(Timestamp))/binary>>;

%% Type 19. Packed output circuit information of protection equipment with time tag
create_information_element(?M_EP_TC_1, #{
  value := OCI,
  qdp := QDP,
  duration := Duration,
  ts := Timestamp
}) ->
  <<OCI, QDP, (get_cp16(Duration)):16/binary, (get_cp24(Timestamp))/binary>>;

%% Type 20. Packed single-point information with status change detection
create_information_element(?M_PS_NA_1, #{
  value := SCD,
  qds := QDS
}) ->
  <<SCD:32/little, QDS>>;

%% Type 21. Measured value, normalized value without QDS
create_information_element(?M_ME_ND_1, #{
  value := NVA
}) ->
  <<NVA:16/little-signed-float>>;

%% Type 30. Single point information with time tag
create_information_element(?M_SP_TB_1, #{
  value := SPI,
  qds := SIQ,
  ts := Timestamp
}) ->
  <<Rest:7, _Ignore:1>> = <<SIQ>>,
  <<Rest:7, SPI:1, (get_cp56(Timestamp))/binary>>;

%% Type 31. Double point information with time tag
create_information_element(?M_DP_TB_1, #{
  value := DPI,
  qds := DIQ,
  ts := Timestamp
}) ->
  <<Rest:6, _Ignore:2>> = <<DIQ>>,
  <<Rest:6, DPI:2, (get_cp56(Timestamp))/binary>>;

%% Type 32. Step position information with time tag
create_information_element(?M_ST_TB_1, #{
  value := Value,
  vti := VTI,
  qds := QDS,
  ts := Timestamp
}) ->
  <<State:1, _Ignore:7>> = <<VTI>>,
  <<State:1, Value:7, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 33. Bit string of 32 bit with time tag
create_information_element(?M_BO_TB_1, #{
  value := BSI,
  qds := QDS,
  ts := Timestamp
}) ->
  <<BSI:32/little-unsigned, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 34. Measured value, normalized value with time tag
create_information_element(?M_ME_TD_1, #{
  value := NVA,
  qds := QDS,
  ts := Timestamp
}) ->
  <<NVA:16/little-signed-float, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 35. Measured value, scaled value with time tag
create_information_element(?M_ME_TE_1, #{
  value := SVA,
  qds := QDS,
  ts := Timestamp
}) ->
  <<SVA:16/little-signed, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 36. Measured value, short floating point value with time tag
create_information_element(?M_ME_TF_1, #{
  value := Value,
  qds := QDS,
  ts := Timestamp
}) ->
  <<Value:32/little-signed-float, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 37. Integrated totals with time tag
create_information_element(?M_IT_TB_1, #{
  value := Value,
  bcr := BCR,
  ts := Timestamp
}) ->
  <<_Ignore:32, Rest:8>> = <<BCR:40>>,
  <<Value:32/little-signed, Rest:8, (get_cp56(Timestamp))/binary>>;

%% Type 38. Event of protection equipment with time tag
create_information_element(?M_EP_TD_1, #{
  value := ES,
  sep := SEP,
  interval := Interval,
  ts := Timestamp
}) ->
  <<Rest:6, _Ignore:2>> = <<SEP>>,
  <<Rest:6, ES:2, Interval:16/little-unsigned, (get_cp56(Timestamp))/binary>>;

%% Type 70. End of initialization
create_information_element(?M_EI_NA_1, #{
  value => Value,
  coi => COI
}) ->
  <<COI:1, _Ignore:7>> = <<COI>>,
  <<COI, Value>>;

%% Type 100. Group request
create_information_element(?C_IC_NA_1, GroupID) ->
  <<(GroupID + ?COT_GROUP_MIN)>>;

%% Type 101. Group counter request
create_information_element(?C_CI_NA_1, GroupCounterID) ->
  <<(GroupCounterID + ?COT_GROUP_COUNTER_MIN)>>;

%% Type 103. Clock synchronization
create_information_element(?C_CS_NA_1, Timestamp) ->
  get_cp56(Timestamp);

create_information_element(OtherType, _) -> throw({unsupported_type, OtherType}).

%% +--------------------------------------------------------------+
%% |                     Internal functions                       |
%% +--------------------------------------------------------------+

parse_cp16(<<CP/unsigned-integer>>) ->
  CP.

parse_cp24(<<
  Milliseconds:16 /little-integer,
  _Reserved1:2,
  Minutes:6       /integer,
  _Reserved2:3,
  Hours:5         /integer,
  _IgnoredRest    /binary
>> = CP) ->
  try
    Seconds = millis_to_seconds(Milliseconds),
    Time = {Hours, Minutes, Seconds},
    calendar:datetime_to_gregorian_seconds({?UNIX_EPOCH_DATE, Time}) * 1000 - 62167219200000
  catch
    _:Error ->
      ?LOGERROR("Timestamp error: ~p. Timestamp: ~p", [CP, Error]),
      undefined
  end.

parse_cp56(CP) ->
  <<
    Milliseconds:16/little-integer,
    _R1:2,
    Min:6  /integer,
    _R2:3,
    H:5    /integer,
    _WD:3  /integer,
    D:5    /integer,
    _R3:4,
    MN:4   /integer,
    _res4:1,
    Y:7    /integer
  >> = CP,
  try
    [DT | _] = calendar:local_time_to_universal_time_dst({
      {Y + 2000, MN, D},
      {H, Min, (Milliseconds div 1000)}
    }),
    calendar:datetime_to_gregorian_seconds(DT) * 1000 - 62167219200000
  catch
    _:Error ->
      ?LOGERROR("parse_cp56 error: ~p, Timestamp: ~p", [CP, Error]),
      none
  end.

get_cp16(undefined) -> get_cp16(0);
get_cp16(Value) ->
  <<Value/unsigned-integer>>.

get_cp56(undefined) -> get_cp56(0);
get_cp56(Value) ->
  try
    Gs = (Value + 62167219200000) div 1000,
    {{Y, MN, D}, {H, Min, S}} = calendar:gregorian_seconds_to_datetime(Gs),
    Ms = S * 1000 + (Value + 62167219200000) - Gs * 1000,
    WD = calendar:day_of_the_week(Y, MN, D),
    YCP56 = Y - 2000,
    <<Ms:16/little-integer, 16#00:2, Min:6/integer, 16#00:3, H:5/integer, WD:3/integer, D:5/integer, 16#00:4, MN:4/integer, 16#00:1, YCP56:7/integer>>
  catch
    _:Error ->
      ?LOGERROR("Timestamp error: ~p. Timestamp: ~p", [Value, Error]),
      undefined
  end.

get_cp24(undefined) -> get_cp24(0);
get_cp24(Value) ->
  try
    Gs = (Value + 62167219200000) div 1000,
    {{_, _, _}, {H, Minutes, S}} = calendar:gregorian_seconds_to_datetime(Gs),
    Millis = S * 1000 + (Value + 62167219200000) - Gs * 1000,
    <<Millis:16/little-integer, 16#00:2, Minutes:6/integer, 16#00:3, H:5/integer>>
  catch
    _:Error ->
      ?LOGERROR("Timestamp error: ~p. Timestamp: ~p", [Value, Error]),
      undefined
  end.

millis_to_seconds(Milliseconds) -> Milliseconds div 1000.