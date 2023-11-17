%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+

-module(iec60870_type).

-include("iec60870.hrl").
-include("asdu.hrl").

-export([
  parse_information_element/2,
  create_information_element/2,
  get_cp24/1,
  parse_cp24/1
]).

-define(MILLIS_IN_MINUTE, 60000).
-define(UNIX_EPOCH_DATE, {1970, 1, 1}).
-define(UNIX_EPOCH_SECONDS, 62167219200).
-define(CURRENT_MILLENNIUM, 2000).
-define(SHORT_INT_MAX_VALUE, 32767).

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
parse_information_element(?M_ME_NA_1, <<NVA:16/little-signed, QDS>>) ->
  #{value => parse_nva(NVA), qds => QDS};

%% Type 10. Measured value, normalized value with time tag
parse_information_element(?M_ME_TA_1, <<NVA:16/little-signed, QDS, Timestamp/binary>>) ->
  #{value => parse_nva(NVA), qds => QDS, ts => parse_cp24(Timestamp)};

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
parse_information_element(?M_ME_ND_1, <<NVA:16/little-signed>>) ->
  #{value => parse_nva(NVA)};

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
parse_information_element(?M_ME_TD_1, <<NVA:16/little-signed, QDS, Timestamp/binary>>) ->
  #{value => parse_nva(NVA), qds => QDS, ts => parse_cp56(Timestamp)};

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
  <<Rest:7, (round(SPI)):1>>;

%% Type 2. Single point information with time tag
create_information_element(?M_SP_TA_1, #{
  value := SPI,
  siq := SIQ,
  ts := Timestamp
}) ->
  <<Rest:7, _Ignore:1>> = <<SIQ>>,
  <<Rest:7, (round(SPI)):1, (get_cp24(Timestamp))/binary>>;

%% Type 3. Double point information
create_information_element(?M_DP_NA_1, #{
  value := DPI,
  diq := DIQ
}) ->
  <<Rest:6, _Ignore:2>> = <<DIQ>>,
  <<Rest:6, (round(DPI)):2>>;

%% Type 4. Double point information with time tag
create_information_element(?M_DP_TA_1, #{
  value := DPI,
  diq := DIQ,
  ts := Timestamp
}) ->
  <<Rest:6, _Ignore:2>> = <<DIQ>>,
  <<Rest:6, (round(DPI)):2, (get_cp24(Timestamp))/binary>>;

%% Type 5. Step position information
create_information_element(?M_ST_NA_1, #{
  value := Value,
  vti := VTI,
  qds := QDS
}) ->
  <<State:1, _Ignore:7>> = <<VTI>>,
  <<State:1, (round(Value)):7/signed, QDS>>;

%% Type 6. Step position information with time tag
create_information_element(?M_ST_TA_1, #{
  value := Value,
  vti := VTI,
  qds := QDS,
  ts := Timestamp
}) ->
  <<State:1, _Ignore:7>> = <<VTI>>,
  <<State:1, (round(Value)):7/signed, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 7. Bit string of 32 bit
create_information_element(?M_BO_NA_1, #{
  value := BSI,
  qds := QDS
}) ->
  <<(round(BSI)):32/little-unsigned, QDS>>;

%% Type 8. Bit string of 32 bit with time tag
create_information_element(?M_BO_TA_1, #{
  value := BSI,
  qds := QDS,
  ts := Timestamp
}) ->
  <<(round(BSI)):32/little-unsigned, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 9. Measured value, normalized value
create_information_element(?M_ME_NA_1, #{
  value := NVA,
  qds := QDS
}) ->
  <<(round(get_nva(NVA))):16/little-signed, QDS>>;

%% Type 10. Measured value, normalized value with time tag
create_information_element(?M_ME_TA_1, #{
  value := NVA,
  qds := QDS,
  ts := Timestamp
}) ->
  <<(round(get_nva(NVA))):16/little-signed, QDS, (get_cp24(Timestamp))/binary>>;

%% Type 11. Measured value, scaled value
create_information_element(?M_ME_NB_1, #{
  value := SVA,
  qds := QDS
}) ->
  <<(round(SVA)):16/little-signed, QDS>>;

%% Type 12. Measured value, scaled value with time tag
create_information_element(?M_ME_TB_1, #{
  value := SVA,
  qds := QDS,
  ts := Timestamp
}) ->
  <<(round(SVA)):16/little-signed, QDS, (get_cp24(Timestamp))/binary>>;

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
  <<(round(Value)):32/little-signed, Rest>>;

%% Type 16. Integrated totals with time tag
create_information_element(?M_IT_TA_1, #{
  value := Value,
  bcr := BCR,
  ts := Timestamp
}) ->
  <<_Ignore:32, Rest>> = <<BCR:40>>,
  <<(round(Value)):32/little-signed, Rest, (get_cp24(Timestamp))/binary>>;

%% Type 17. Protection equipment with time tag
create_information_element(?M_EP_TA_1, #{
  value := ES,
  sep := SEP,
  duration := Duration,
  ts := Timestamp
}) ->
  <<Rest:6, _Ignore:2>> = <<SEP>>,
  <<Rest:6, (round(ES)):2, (get_cp16(Duration)):16/binary, (get_cp24(Timestamp))/binary>>;

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
  <<(round(SCD)):32/little, QDS>>;

%% Type 21. Measured value, normalized value without QDS
create_information_element(?M_ME_ND_1, #{
  value := NVA
}) ->
  <<(round(get_nva(NVA))):16/little-signed>>;

%% Type 30. Single point information with time tag
create_information_element(?M_SP_TB_1, #{
  value := SPI,
  qds := SIQ,
  ts := Timestamp
}) ->
  <<Rest:7, _Ignore:1>> = <<SIQ>>,
  <<Rest:7, (round(SPI)):1, (get_cp56(Timestamp))/binary>>;

%% Type 31. Double point information with time tag
create_information_element(?M_DP_TB_1, #{
  value := DPI,
  qds := DIQ,
  ts := Timestamp
}) ->
  <<Rest:6, _Ignore:2>> = <<DIQ>>,
  <<Rest:6, (round(DPI)):2, (get_cp56(Timestamp))/binary>>;

%% Type 32. Step position information with time tag
create_information_element(?M_ST_TB_1, #{
  value := Value,
  vti := VTI,
  qds := QDS,
  ts := Timestamp
}) ->
  <<State:1, _Ignore:7>> = <<VTI>>,
  <<State:1, (round(Value)):7, QDS, (get_cp56(Timestamp))/binary>>;

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
  <<(round(get_nva(NVA))):16/little-signed, QDS, (get_cp56(Timestamp))/binary>>;

%% Type 35. Measured value, scaled value with time tag
create_information_element(?M_ME_TE_1, #{
  value := SVA,
  qds := QDS,
  ts := Timestamp
}) ->
  <<(round(SVA)):16/little-signed, QDS, (get_cp56(Timestamp))/binary>>;

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
  <<(round(Value)):32/little-signed, Rest:8, (get_cp56(Timestamp))/binary>>;

%% Type 38. Event of protection equipment with time tag
create_information_element(?M_EP_TD_1, #{
  value := ES,
  sep := SEP,
  interval := Interval,
  ts := Timestamp
}) ->
  <<Rest:6, _Ignore:2>> = <<SEP>>,
  <<Rest:6, (round(ES)):2, Interval:16/little-unsigned, (get_cp56(Timestamp))/binary>>;

%% Type 70. End of initialization
create_information_element(?M_EI_NA_1, #{
  value := Value,
  coi := COI
}) ->
  <<COI:1, _Ignore:7>> = <<COI>>,
  <<COI:1, (round(Value)):7>>;

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

parse_cp16(<<Millis:16/unsigned-integer>>) ->
  Millis;
parse_cp16(InvalidTimestamp) ->
  ?LOGWARNING("Invalid CP16 has been received: ~p", [InvalidTimestamp]),
  undefined.

parse_cp24(<<
  Millis:16/little-integer,
  _Reserved1:2,
  Minutes:6/integer,
  _IgnoredRest/binary
>>) ->
  Millis + (Minutes * ?MILLIS_IN_MINUTE);
parse_cp24(InvalidTimestamp) ->
  ?LOGWARNING("Invalid CP24 has been received: ~p", [InvalidTimestamp]),
  undefined.

parse_cp56(<<
  Millis:16/little-integer,
  _R1:2,
  Minutes:6  /integer,
  _R2:3,
  Hours:5    /integer,
  _WD:3  /integer,
  Day:5    /integer,
  _R3:4,
  Month:4   /integer,
  _R4:1,
  Year:7    /integer
>> = Timestamp) ->
  try
    DateTime =
      {{Year + ?CURRENT_MILLENNIUM, Month, Day}, {Hours, Minutes, millis_to_seconds(Millis)}},
    [UTC] = calendar:local_time_to_universal_time_dst(DateTime),
    GregorianSeconds = calendar:datetime_to_gregorian_seconds(UTC),
    seconds_to_millis(GregorianSeconds - ?UNIX_EPOCH_SECONDS)
  catch
    _:Error ->
      ?LOGERROR("CP56 parse error: ~p, timestamp: ~p", [Error, Timestamp]),
      none
  end.

get_cp16(undefined) -> get_cp16(0);
get_cp16(Value) ->
  <<Value/unsigned-integer>>.

get_cp24(undefined) -> get_cp24(0);
get_cp24(Millis) ->
  try
    <<(round(Millis rem ?MILLIS_IN_MINUTE)):16/little-integer,
      16#00:2, (round(Millis / ?MILLIS_IN_MINUTE)):6/integer>>
  catch
    _:Error ->
      ?LOGERROR("CP24 get error: ~p, timestamp: ~p", [Error, Millis]),
      undefined
  end.

get_cp56(undefined) -> get_cp56(0);
get_cp56(PosixTimestamp) ->
  try
    GregorianSeconds = millis_to_seconds(PosixTimestamp) + ?UNIX_EPOCH_SECONDS,
    UTC = calendar:gregorian_seconds_to_datetime(GregorianSeconds),
    {{Year, Month, Day}, {Hour, Minute, Seconds}} =
      calendar:universal_time_to_local_time(UTC),
    WeekDay = calendar:day_of_the_week(Year, Month, Day),
    <<(seconds_to_millis(Seconds)):16/little-integer,
      16#00:2,
      Minute:6  /integer,
      16#00:3,
      Hour:5    /integer,
      WeekDay:3 /integer,
      Day:5     /integer,
      16#00:4,
      Month:4   /integer,
      16#00:1,
      (Year - ?CURRENT_MILLENNIUM):7/integer>>
  catch
    _:Error ->
      ?LOGERROR("CP56 get error: ~p, timestamp: ~p", [Error, PosixTimestamp]),
      undefined
  end.

millis_to_seconds(Millis) -> Millis div 1000.
seconds_to_millis(Seconds) -> Seconds * 1000.

parse_nva(Value) -> Value / ?SHORT_INT_MAX_VALUE.
get_nva(Value) -> Value * ?SHORT_INT_MAX_VALUE.