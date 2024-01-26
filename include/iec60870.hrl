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

-define(DATA(Connection, Data), {data, Connection, Data}).
-define(OBJECT(Type, COT, IOA, Value), {object, Type, COT, IOA, Value}).

%% Structure Qualifier (SQ) types:
%% 0 - Different IOAs
%% 1 - Continuous IOAs
-define(SQ_0, 16#00:1).
-define(SQ_1, 16#01:1).

%% Monitor direction types
-define(M_SP_NA_1, 16#01). %  1: SIQ                                     | Single point information
-define(M_SP_TA_1, 16#02). %  2: SIQ + CP24Time2A                        | Single point information with time tag
-define(M_DP_NA_1, 16#03). %  3: DIQ                                     | Double point information
-define(M_DP_TA_1, 16#04). %  4: DIQ + CP24Time2A                        | Double point information with time tag
-define(M_ST_NA_1, 16#05). %  5: VTI + QDS                               | Step position information
-define(M_ST_TA_1, 16#06). %  6: VTI + QDS + CP24Time2A                  | Step position information with time tag
-define(M_BO_NA_1, 16#07). %  7: BSI + QDS                               | Bit string of 32 bit
-define(M_BO_TA_1, 16#08). %  8: BSI + QDS + CP24Time2A                  | Bit string of 32 bit with time tag
-define(M_ME_NA_1, 16#09). %  9: NVA + QDS                               | Measured value, normalized value
-define(M_ME_TA_1, 16#0A). % 10: NVA + QDS + CP24Time2A                  | Measured value, normalized value with time tag
-define(M_ME_NB_1, 16#0B). % 11: SVA + QDS                               | Measured value, scaled value
-define(M_ME_TB_1, 16#0C). % 12: SVA + QDS + CP24Time2A                  | Measured value, scaled value with time tag
-define(M_ME_NC_1, 16#0D). % 13: IEEE STD 754 + QDS                      | Measured value, short floating point
-define(M_ME_TC_1, 16#0E). % 14: IEEE STD 754 + QDS + CP24Time2A         | Measured value, short floating point with time tag
-define(M_IT_NA_1, 16#0F). % 15: BCR                                     | Integrated totals
-define(M_IT_TA_1, 16#10). % 16: BCR + CP24Time2A                        | Integrated totals with time tag
-define(M_EP_TA_1, 16#11). % 17: CP16Time2A + CP24Time2A                 | Protection equipment with time tag
-define(M_EP_TB_1, 16#12). % 18: SEP + QDP + C + CP16Time2A + CP24Time2A | Packed events of protection equipment with time tag
-define(M_EP_TC_1, 16#13). % 19: OCI + QDP + CP16Time2A + CP24Time2A     | Packed output circuit information of protection equipment with time tag
-define(M_PS_NA_1, 16#14). % 20: SCD + QDS                               | Packed single-point information with status change detection
-define(M_ME_ND_1, 16#15). % 21: NVA                                     | Measured value, normalized value without QDS
%% There are no types from 22 to 29
-define(M_SP_TB_1, 16#1E). % 30: SIQ + CP56Time2A                        | Single point information with time tag
-define(M_DP_TB_1, 16#1F). % 31: DIQ + CP56Time2A                        | Double point information with time tag
-define(M_ST_TB_1, 16#20). % 32: VTI + QDS + CP56Time2A                  | Step position information with time tag
-define(M_BO_TB_1, 16#21). % 33: BSI + QDS + CP56Time2A                  | Bit string of 32 bit with time tag
-define(M_ME_TD_1, 16#22). % 34: NVA + QDS + CP56Time2A                  | Measured value, normalized value with time tag
-define(M_ME_TE_1, 16#23). % 35: SVA + QDS + CP56Time2A                  | Measured value, scaled value with time tag
-define(M_ME_TF_1, 16#24). % 36: IEEE STD 754 + QDS + CP56Time2A         | Measured value, short floating point value with time tag
-define(M_IT_TB_1, 16#25). % 37: BCR + CP56Time2A                        | Integrated totals with time tag
-define(M_EP_TD_1, 16#26). % 38: CP16Time2A + CP56Time2A                 | Event of protection equipment with time tag
-define(M_EI_NA_1, 16#46). % 70: Initialization Ending

%% Remote control commands without time tag
-define(C_SC_NA_1, 16#2D). % 45: Single command
-define(C_DC_NA_1, 16#2E). % 46: Double command
-define(C_RC_NA_1, 16#2F). % 47: Regulating step command
-define(C_SE_NA_1, 16#30). % 48: Set point command, normalized value
-define(C_SE_NB_1, 16#31). % 49: Set point command, scaled value
-define(C_SE_NC_1, 16#32). % 50: Set point command, short floating point value
-define(C_BO_NA_1, 16#33). % 51: Bit string 32 bit

%% Remote control commands with time tag
-define(C_SC_TA_1, 16#3A). % 58: Single command (time tag)
-define(C_DC_TA_1, 16#3B). % 59: Double command
-define(C_RC_TA_1, 16#3C). % 60: Regulating step command
-define(C_SE_TA_1, 16#3D). % 61: Set point command, normalized value
-define(C_SE_TB_1, 16#3E). % 62: Set point command, scaled value
-define(C_SE_TC_1, 16#3F). % 63: Set point command, short floating point value
-define(C_BO_TA_1, 16#40). % 64: Bit string 32 bit

%% Remote control commands on system information
-define(C_IC_NA_1, 16#64). % 100: Group Request Command
-define(C_CI_NA_1, 16#65). % 101: Counter Interrogation Command
-define(C_CS_NA_1, 16#67). % 103: Clock Synchronization Command
-define(C_TS_NA_1, 16#68). % 104: Test Command

-define(DEFAULT_HANDSHAKE_TIMEOUT, 30000).
-define(DEFAULT_WRITE_TIMEOUT, 30000).

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