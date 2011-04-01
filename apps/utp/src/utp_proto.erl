-module(utp_proto).

-include("utp.hrl").

-ifdef(TEST).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([mk_connection_id/0,
	 payload_size/1,
	 send_packet/3,
	 encode/2,
	 decode/1]).

-define(EXT_SACK, 1).
-define(EXT_BITS, 2).

-define(ST_DATA,  0).
-define(ST_FIN,   1).
-define(ST_STATE, 2).
-define(ST_RESET, 3).
-define(ST_SYN,   4).

-spec mk_connection_id() -> 0..65535.
mk_connection_id() ->
    <<N:16/integer>> = crypto:rand_bytes(2),
    N.

payload_size(#packet { payload = PL }) ->
    byte_size(PL).

-spec current_time_us() -> integer().
current_time_us() ->
    {M, S, Micro} = os:timestamp(),
    S1 = M*1000000 + S,
    Micro + S1*1000000.

timediff(Ts, Last) ->
    Ts - Last. %% @todo this has to be a lot more clever than it currently is!

send_packet(Packet, LastTS, Socket) ->
    TS = current_time_us(),
    Diff = timediff(TS,LastTS),
    gen_udp:send(Socket, Packet, TS, Diff).

-spec encode(packet(), timestamp()) -> binary().
encode(#packet { ty = Type,
		 conn_id = ConnID,
		 win_sz = WSize,
		 seq_no = SeqNo,
		 ack_no = AckNo,
		 extension = ExtList,
		 payload = Payload}, TSDiff) ->
    {Extension, ExtBin} = encode_extensions(ExtList),
    EncTy = encode_type(Type),
    TS    = current_time_us(),
    <<1:4/integer, EncTy:4/integer, Extension:8/integer, ConnID:16/integer,
      TS:32/integer,
      TSDiff:32/integer,
      WSize:32/integer,
      SeqNo:16/integer, AckNo:16/integer,
      ExtBin/binary,
      Payload/binary>>.

-spec decode(binary()) -> {packet(), timestamp(), timestamp()}.
decode(Packet) ->
    TS = current_time_us(),
    case Packet of
	<<1:4/integer, Type:4/integer, Extension:8/integer, ConnectionId:16/integer,
	  TimeStamp:32/integer,
	  TimeStampdiff:32/integer,
	  WindowSize:32/integer,
	  SeqNo:16/integer, AckNo:16/integer,
	ExtPayload/binary>> ->
	    {Extensions, Payload} = decode_extensions(Extension, ExtPayload, []),
	    Ty = decode_type(Type),
	    if
		Ty == st_state ->
		    <<>> = Payload;
		true ->
		    ok
	    end,
	    {#packet { ty = decode_type(Type),
		       conn_id = ConnectionId,
		       win_sz = WindowSize,
		       seq_no = SeqNo,
		       ack_no = AckNo,
		       extension = Extensions,
		       payload = Payload},
	     TimeStamp,
	     TimeStampdiff,
	     TS}
    end.

decode_extensions(0, Payload, Exts) ->
    {lists:reverse(Exts), Payload};
decode_extensions(?EXT_SACK, <<Next:8/integer,
			       Len:8/integer, R/binary>>, Acc) ->
    <<Bits:Len/binary, Rest/binary>> = R,
    decode_extensions(Next, Rest, [{sack, Bits} | Acc]);
decode_extensions(?EXT_BITS, <<Next:8/integer,
			       Len:8/integer, R/binary>>, Acc) ->
    <<ExtBits:Len/binary, Rest/binary>> = R,
    decode_extensions(Next, Rest, [{ext_bits, ExtBits} | Acc]).

encode_extensions([]) -> {0, <<>>};
encode_extensions([{sack, Bits} | R]) ->
    {Next, Bin} = encode_extensions(R),
    Sz = byte_size(Bits),
    {?EXT_SACK, <<Next:8/integer, Sz:8/integer, Bits/binary, Bin/binary>>};
encode_extensions([{ext_bits, Bits} | R]) ->
    {Next, Bin} = encode_extensions(R),
    Sz = byte_size(Bits),
    {?EXT_BITS, <<Next:8/integer, Sz:8/integer, Bits/binary, Bin/binary>>}.

decode_type(?ST_DATA) -> st_data;
decode_type(?ST_FIN) -> st_fin;
decode_type(?ST_STATE) -> st_state;
decode_type(?ST_RESET) -> st_reset;
decode_type(?ST_SYN) -> st_syn.

encode_type(st_data) -> ?ST_DATA;
encode_type(st_fin) -> ?ST_FIN;
encode_type(st_state) -> ?ST_STATE;
encode_type(st_reset) -> ?ST_RESET;
encode_type(st_syn) -> ?ST_SYN.

-ifdef(EUNIT).
-ifdef(EQC).

g_type() ->
    oneof([st_data, st_fin, st_state, st_reset, st_syn]).

g_timestamp() ->
    choose(0, 256*256*256*256-1).

g_uint32() ->
    choose(0, 256*256*256*256-1).

g_uint16() ->
    choose(0, 256*256-1).

g_extension_one() ->
    ?LET({What, Bin}, {oneof([sack, ext_bits]), binary()},
	 {What, Bin}).

g_extension() ->
    list(g_extension_one()).

g_packet() ->
    ?LET({Ty, ConnID, WindowSize, SeqNo, AckNo,
	  Extension, Payload},
	 {g_type(), g_uint16(), g_uint32(), g_uint16(), g_uint16(),
	  g_extension(), binary()},
	 #packet { ty = Ty, conn_id = ConnID, win_sz = WindowSize,
		   seq_no = SeqNo, ack_no = AckNo, extension = Extension,
		   payload = Payload }).

prop_ext_dec_inv() ->
    ?FORALL(E, g_extension(),
	    begin
		{Next, B} = encode_extensions(E),
		{E, <<>>} =:= decode_extensions(Next, B, [])
	    end).

prop_decode_inv() ->
    ?FORALL({P, T1, T2}, {g_packet(), g_timestamp(), g_timestamp()},
	    begin
		{P, T1, T2} =:= decode(encode(P, T1, T2))
	    end).

inverse_extension_test() ->
    ?assert(eqc:quickcheck(prop_ext_dec_inv())).

inverse_decode_test() ->
    ?assert(eqc:quickcheck(prop_decode_inv())).

-endif.
-endif.

