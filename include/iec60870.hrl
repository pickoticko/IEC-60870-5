%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-ifndef(iec60870).
-define(iec608701, 1).

-define(LOGERROR(Text), logger:error(Text)).
-define(LOGERROR(Text,Params), logger:error( Text, Params)).
-define(LOGWARNING(Text), logger:warning(Text)).
-define(LOGWARNING(Text,Params), logger:warning(Text, Params)).
-define(LOGINFO(Text), logger:info(Text)).
-define(LOGINFO(Text,Params), logger:info(Text, Params)).
-define(LOGDEBUG(Text), logger:debug(Text)).
-define(LOGDEBUG(Text,Params), logger:debug(Text,Params)).


%%-define(LOGERROR(Text),           io:format("ERROR: "++Text++"\r\n")).
%%-define(LOGERROR(Text, Params),   io:format("ERROR: "++Text++"\r\n", Params)).
%%-define(LOGWARNING(Text),         io:format("WARNING: "++Text++"\r\n")).
%%-define(LOGWARNING(Text, Params), io:format("WARNING: "++Text++"\r\n", Params)).
%%-define(LOGINFO(Text),            io:format("INFO: "++Text++"\r\n")).
%%-define(LOGINFO(Text, Params),    io:format("INFO: "++Text++"\r\n", Params)).
%%-define(LOGDEBUG(Text),           io:format("DEBUG: "++Text++"\r\n")).
%%-define(LOGDEBUG(Text, Params),   io:format("DEBUG: "++Text++"\r\n", Params)).

-define(DATA(Connection, Data), {data, Connection, Data}).
-define(OBJECT(Type, COT, IOA, Value), {object, Type, COT, IOA, Value}).

%% Structure Qualifier (SQ) types:
%% 0 - Different IOAs
%% 1 - Continuous IOAs
-define(SQ_0, 16#00:1).
-define(SQ_1, 16#01:1).

%% TODO: Support all types from 1 to 40!
%% Monitor direction types
-define(M_SP_NA_1, 16#01). %   1: SIQ                             Last bit for ON/OFF
-define(M_DP_NA_1, 16#03). %   3: DIQ                             Two element information
-define(M_ME_NA_1, 16#09). %   9: NVA + QDS                       Little integer 16bit ( V / 32768 )  and 1 byte for QDS
-define(M_ME_NB_1, 16#0B). %  11: SVA + QDS                       Little integer 16bit and 1 byte for QDS
-define(M_ME_NC_1, 16#0D). %  13: SVA + QDS                       Float 32 bit and 1 byte for QDS
-define(M_SP_TB_1, 16#1E). %  30: SIQ + CP56Time2a                Last bit for ON/OFF and 7 bytes of datetime
-define(M_DP_TB_1, 16#1F). %  31: DIQ + CP56Time2a                Two element information
-define(M_ME_TF_1, 16#24). %  36: IEEE STD 754 + QDS + CP56Time2a Float 32bit, 1 byte for QDS and 7 bytes of datetime
-define(M_EP_TF_1, 16#28). %  40: Packed output circuit information
-define(M_EI_NA_1, 16#46). %  70: Initialization Ending

%% Control direction types
-define(C_IC_NA_1, 16#64). % 100: Group Request Command
-define(C_CI_NA_1, 16#65). % 101: Counter Interrogation Command
-define(C_CS_NA_1, 16#67). % 103: Clock Synchronization Command

-define(INIT_ADDRESS, 16#00).

%% Max objects each ASDU can contain
-define(MAX_PACKETS, 127).
-define(EMPTY_QDS, 2#00000000).

%% Limitations
-define(MAX_FRAME_LIMIT, 32767).
-define(MIN_FRAME_LIMIT, 1).

-define(MAX_COA, 65535).
-define(MIN_COA, 0).
-define(MAX_ORG, 255).
-define(MIN_ORG, 0).

-define(MAX_IOA_BYTES, 3).
-define(MIN_IOA_BYTES, 1).
-define(MAX_COA_BYTES, 2).
-define(MIN_COA_BYTES, 1).
-define(MAX_ORG_BYTES, 1).
-define(MIN_ORG_BYTES, 0).

-endif.