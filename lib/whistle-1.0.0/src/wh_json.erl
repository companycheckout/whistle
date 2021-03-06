%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% proplists-like interface to json objects
%%% @end
%%% Created : 2 Feb 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(wh_json).

-export([get_binary_boolean/2, get_binary_boolean/3]).
-export([get_integer_value/2, get_integer_value/3]).
-export([get_binary_value/2, get_binary_value/3]).
-export([is_true/2, is_true/3, is_false/2, is_false/3]).

-export([get_value/2, get_value/3]).
-export([set_value/3]).
-export([delete_key/2, delete_key/3]).

-export([normalize_jobj/1]).

%% not for public use
-export([prune/2, no_prune/2]).

-include_lib("whistle/include/whistle_types.hrl").

-spec(get_binary_value/2 :: (Key :: term(), Doc :: json_object() | json_objects()) -> undefined | binary()).
get_binary_value(Key, JObj) ->
    case wh_json:get_value(Key, JObj) of
        undefined -> undefined;
        Value -> whistle_util:to_binary(Value)
    end.

-spec(get_binary_value/3 :: (Key :: term(), Doc :: json_object() | json_objects(), Default :: binary()) -> binary()).
get_binary_value(Key, JObj, Default) ->
    case wh_json:get_value(Key, JObj) of
        undefined -> Default;
        Value -> whistle_util:to_binary(Value)
    end.

-spec(get_integer_value/2 :: (Key :: term(), Doc :: json_object() | json_objects()) -> undefined | integer()).
get_integer_value(Key, JObj) ->
    case wh_json:get_value(Key, JObj) of
        undefined -> undefined;
        Value -> whistle_util:to_integer(Value)
    end.

-spec(get_integer_value/3 :: (Key :: term(), Doc :: json_object() | json_objects(), Default :: integer()) -> integer()).
get_integer_value(Key, JObj, Default) ->
    case wh_json:get_value(Key, JObj) of
        undefined -> Default;
        Value -> whistle_util:to_integer(Value)
    end.

-spec(is_false/2 :: (Key :: term(), Doc :: json_object() | json_objects()) -> boolean()).
is_false(Key, JObj) ->
    is_false(Key, JObj, true).

-spec(is_false/3 :: (Key :: term(), Doc :: json_object() | json_objects(), Default :: boolean()) -> boolean()).
is_false(Key, JObj, Default) ->
    whistle_util:is_false(wh_json:get_value(Key, JObj, Default)).

-spec(is_true/2 :: (Key :: term(), Doc :: json_object() | json_objects()) -> boolean()).
is_true(Key, JObj) ->
    is_true(Key, JObj, false).

-spec(is_true/3 :: (Key :: term(), Doc :: json_object() | json_objects(), Default :: boolean()) -> boolean()).
is_true(Key, JObj, Default) ->
    whistle_util:is_true(wh_json:get_value(Key, JObj, Default)).

-spec(get_binary_boolean/2 :: (Key :: term(), Doc :: json_object() | json_objects()) -> undefined | binary()).
get_binary_boolean(Key, JObj) ->
    case wh_json:get_value(Key, JObj) of
        undefined -> undefined;
        Value -> whistle_util:to_binary(whistle_util:is_true(Value))
    end.

-spec(get_binary_boolean/3 :: (Key :: term(), Doc :: json_object() | json_objects(), Default :: term()) -> binary()).
get_binary_boolean(Key, JObj, Default) ->
    whistle_util:to_binary(is_true(Key, JObj, Default)).

-spec(get_value/2 :: (Key :: term(), Doc :: json_object() | json_objects()) -> undefined | term()).
get_value(Key, Doc) ->
    get_value(Key, Doc, undefined).

-spec(get_value/3 :: (Key :: term(), Doc :: json_object() | json_objects(), Default :: term()) -> term()).
get_value([Key|Ks], [{struct, _}|_]=L, Default) ->
    try
	get_value1(Ks, lists:nth(Key, L), Default)
    catch
	_:_ -> Default
    end;
get_value(Key, L, Default) when is_list(L) ->
    get_value1(Key, {struct, L}, Default);
get_value(K, Doc, Default) ->
    get_value1(K, Doc, Default).

-spec(get_value1/3 :: (Key :: term(), Doc :: json_object(), Default :: term()) -> term()).
get_value1([], Doc, _Default) -> Doc;
get_value1(Key, Doc, Default) when not is_list(Key)->
    get_value1([Key], Doc, Default);
get_value1([K|Ks], {struct, Props}, Default) ->
    get_value1(Ks, props:get_value(whistle_util:to_binary(K), Props, Default), Default);
get_value1([K|Ks], Doc, Default) when is_list(Doc) ->
    case try lists:nth(whistle_util:to_integer(K), Doc) catch _:_ -> undefined end of
	undefined -> Default;
	Doc1 -> get_value1(Ks, Doc1, Default)
    end;
get_value1(_, _, Default) -> Default.

%% Figure out how to set the current key among a list of objects

-spec(set_value/3 :: (Key :: term(), Value :: term(), Doc :: json_object() | json_objects()) -> json_object() | json_objects()).
set_value(Key, Value, {struct, _}=Doc) ->
    set_value1(Key, Value, Doc);
set_value(Key, Value, [{struct, _} | _]=Docs) ->
    set_value1(Key, Value, Docs).

-spec(set_value1/3 :: (Key :: term(), Value :: term(), Doc :: json_object() | json_objects()) -> json_object() | json_objects()).
set_value1(Key, Value, Doc) when not is_list(Key) ->
    set_value1([Key], Value, Doc);
set_value1([Key|T], Value, [{struct, _}|_]=Doc) ->
    Key1 = whistle_util:to_integer(Key),
    case Key1 > length(Doc) of
        %% The object index does not exist so try to add a new one to the list
        true ->
            try
                %% Create a new object with the next key as a property
                NxtKey = whistle_util:to_binary(hd(T)),
                Doc ++ [set_value1(T, Value, {struct, [{NxtKey, []}]})]
            catch
                %% There are no more keys in the list, add it unless not an object
                error:badarg ->
                    V = try {struct, _} = Value catch _:_ -> erlang:error(badarg) end,
                    Doc ++ [V]
            end;
        %% The object index exists so iterate into the object and updat it
        false ->
            element(1, lists:mapfoldl(fun(E, {Pos, Pos}) ->
                                             {set_value1(T, Value, E), {Pos + 1, Pos}};
                                         (E, {Pos, Idx}) ->
                                             {E, {Pos + 1, Idx}}
                                      end, {1, Key1}, Doc))
    end;
%% Figure out how to set the current key in an existing object
set_value1([Key|T], Value, {struct, Props}) ->
    Key1 = whistle_util:to_binary(Key),
    case lists:keyfind(Key1, 1, Props) of
        {Key1, {struct, _}=V1} ->
            %% Replace or add a property in an object in the object at this key
            {struct, lists:keyreplace(Key1, 1, Props, {Key1, set_value1(T, Value, V1)})};
        {Key1, V1} when is_list(V1) ->
            %% Replace or add a member in an array in the object at this key
            {struct, lists:keyreplace(Key1, 1, Props, {Key1, set_value1(T, Value, V1)})};
        {Key1, _} when T == [] ->
            %% This is the final key and the objects property should just be replaced
            {struct, lists:keyreplace(Key1, 1, Props, {Key1, Value})};
        {Key1, _} ->
            %% This is not the final key and the objects property should just be
            %% replaced so continue looping the keys creating the necessary json as we go
            {struct, lists:keyreplace(Key1, 1, Props, {Key1, set_value1(T, Value, ?EMPTY_JSON_OBJECT)})};
        false when T == [] ->
            %% This is the final key and doesnt already exist, just add it to this
            %% objects existing properties
            {struct, Props ++ [{Key1, Value}]};
        false ->
            %% This is not the final key and this object does not have this key
            %% so continue looping the keys creating the necessary json as we go
            {struct, Props ++ [{Key1, set_value1(T, Value, ?EMPTY_JSON_OBJECT)}]}
    end;
%% There are no more keys to iterate through! Override the value here...
set_value1([], Value, _Doc) -> Value.

%% delete_key(foo, {struct, [{foo, bar}, {baz, biz}]}) -> {struct, [{baz, biz}]}
%% delete_key([foo, far], {struct, [{foo, {struct, [{far, away}]}}, {baz, biz}]}) -> {struct, [{foo, {struct, []}}, {baz, biz}]}

-spec(delete_key/2 :: (Key :: list() | binary(), JObj :: json_object() | json_objects()) -> json_object() | json_objects()).
delete_key(Key, JObj) when not is_list(Key) ->
    delete_key([Key], JObj, no_prune);
delete_key(Keys, JObj) ->
    delete_key(Keys, JObj, no_prune).

%% prune removes the parent key if the result of the delete is an empty list; no prune leaves the parent intact
%% so, delete_key([<<"k1">>, <<"k1.1">>], {struct, [{<<"k1">>, {struct, [{<<"k1.1">>, <<"v1.1">>}]}}]}) would result in
%%   no_prune -> {struct, [{<<"k1">>, []}]}
%%   prune -> {struct, []}
-spec(delete_key/3 :: (Keys :: list() | binary(), JObj :: json_object() | json_objects(), PruneOpt :: prune | no_prune) -> json_object() | json_objects()).
delete_key(Key, JObj, PruneOpt) when not is_list(Key) ->
    (?MODULE):PruneOpt([Key], JObj);
delete_key(Keys, JObj, PruneOpt) ->
    (?MODULE):PruneOpt(Keys, JObj).

prune([], JObj) ->
    JObj;
prune([K], {struct, Doc}) ->
    case lists:keydelete(K, 1, Doc) of
	[] -> ?EMPTY_JSON_OBJECT;
	L -> {struct, L}
    end;
prune([K|T], {struct, Doc}=JObj) ->
    case props:get_value(K, Doc) of
	undefined -> JObj;
	V ->
	    case prune(T, V) of
		?EMPTY_JSON_OBJECT ->
		    {struct, lists:keydelete(K, 1, Doc)};
		[] ->
		    {struct, lists:keydelete(K, 1, Doc)};
		V1 ->
		    {struct, [{K, V1} | lists:keydelete(K, 1, Doc)]}
	    end
    end;
prune(_, []) -> [];
prune([K|T], [_|_]=JObjs) ->
    V = lists:nth(K, JObjs),
    case prune(T, V) of
	?EMPTY_JSON_OBJECT ->
	    replace_in_list(K, undefined, JObjs, []);
	V ->
	    replace_in_list(K, undefined, JObjs, []);
	V1 ->
	    replace_in_list(K, V1, JObjs, [])
    end.

no_prune([], JObj) ->
    JObj;
no_prune([K], {struct, Doc}) ->
    case lists:keydelete(K, 1, Doc) of
	[] -> ?EMPTY_JSON_OBJECT;
	L -> {struct, L}
    end;
no_prune([K|T], {struct, Doc}=JObj) ->
    case props:get_value(K, Doc) of
	undefined -> JObj;
	V ->
	    {struct, [{K, no_prune(T, V)} | lists:keydelete(K, 1, Doc)]}
    end;
no_prune(_, []) -> [];
no_prune([K|T], [_|_]=JObjs) when is_integer(K) ->
    V = lists:nth(K, JObjs),
    V1 = no_prune(T, V),
    case V1 =:= V of
	true ->
	    replace_in_list(K, undefined, JObjs, []);
	false ->
	    replace_in_list(K, V1, JObjs, [])
    end.

replace_in_list(N, _, _, _) when N < 1 ->
    exit(badarg);
replace_in_list(1, undefined, [_OldV | Vs], Acc) ->
    lists:reverse(Acc) ++ Vs;
replace_in_list(1, V1, [_OldV | Vs], Acc) ->
    lists:reverse([V1 | Acc]) ++ Vs;
replace_in_list(N, V1, [V | Vs], Acc) ->
    replace_in_list(N-1, V1, Vs, [V | Acc]).

%%--------------------------------------------------------------------
%% @doc
%% Normalize a JSON object for storage as a Document
%% All dashes are replaced by underscores, all upper case character are
%% converted to lower case
%%
%% @end
%%--------------------------------------------------------------------
-spec(normalize_jobj/1 :: (JObj :: json_object() | {Key :: binary(),  {struct, DataTuples :: json_array()}}) -> json_object() | {binary(), json_object()}).
normalize_jobj({struct, DataTuples}) ->
    {struct, [normalizer(DT) || DT <- DataTuples]};
normalize_jobj({Key, {struct, DataTuples}}) ->
    {normalize_key(Key), {struct, [normalizer(DT) || DT <- DataTuples]}}.

-spec(normalize_binary_tuple/1 :: (BinaryTuple :: tuple(binary(), binary())) -> tuple(binary(), binary()) ).
normalize_binary_tuple({Key,Val}) ->
    {normalize_key(Key), Val}.

-spec(normalize_key/1 :: (Key :: binary()) -> binary()).
normalize_key(Key) when is_binary(Key) ->
    << <<(normalize_key_char(B))>> || <<B>> <= Key>>.

-spec(normalize_key_char/1 :: (C :: char()) -> char()).
normalize_key_char($-) -> $_;
normalize_key_char(C) when is_integer(C), $A =< C, C =< $Z -> C + 32;
%% Converts latin capital letters to lowercase, skipping 16#D7 (extended ascii 215) "multiplication sign: x"
normalize_key_char(C) when is_integer(C), 16#C0 =< C, C =< 16#D6 -> C + 32; % from string:to_lower
normalize_key_char(C) when is_integer(C), 16#D8 =< C, C =< 16#DE -> C + 32; % so we only loop once
normalize_key_char(C) -> C.

-spec(normalizer/1 :: (DataTuple :: {binary(), json_object()} | {binary(), binary()}) -> json_object() | {binary(),  binary()}).
normalizer({_, {struct, _}}=DataTuple) ->
    normalize_jobj(DataTuple);
normalizer({_,_}=DataTuple) ->
    normalize_binary_tuple(DataTuple).

%% EUNIT TESTING
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(D1, {struct, [{<<"d1k1">>, "d1v1"}, {<<"d1k2">>, d1v2}, {<<"d1k3">>, ["d1v3.1", "d1v3.2", "d1v3.3"]}]}).
-define(D2, {struct, [{<<"d2k1">>, 1}, {<<"d2k2">>, 3.14}, {<<"sub_d1">>, ?D1}]}).
-define(D3, {struct, [{<<"d3k1">>, <<"d3v1">>}, {<<"d3k2">>, []}, {<<"sub_docs">>, [?D1, ?D2]}]}).
-define(D4, [?D1, ?D2, ?D3]).

-define(D6, {struct, [{<<"d2k1">>, 1}
		      ,{<<"d2k2">>, 3.14}
		      ,{<<"sub_d1">>, {struct, [{<<"d1k1">>, "d1v1"}]}}
		     ]
	    }).
-define(D7, {struct, [{<<"d1k1">>, <<"d1v1">>}]}).

%% delete results
-define(D1_AFTER_K1, {struct, [{<<"d1k2">>, d1v2}, {<<"d1k3">>, ["d1v3.1", "d1v3.2", "d1v3.3"]}]}).
-define(D1_AFTER_K3_V2, {struct, [{<<"d1k3">>, ["d1v3.1", "d1v3.3"]}, {<<"d1k1">>, "d1v1"}, {<<"d1k2">>, d1v2}]}).

-define(D6_AFTER_SUB, {struct, [{<<"sub_d1">>, {struct, []}}
				,{<<"d2k1">>, 1}
				,{<<"d2k2">>, 3.14}
			       ]
			 }).
-define(D6_AFTER_SUB_PRUNE, {struct, [{<<"d2k1">>, 1}
				      ,{<<"d2k2">>, 3.14}
				     ]
			    }).

-spec(delete_key_test/0 :: () -> no_return()).
delete_key_test() ->
    ?assertEqual(?EMPTY_JSON_OBJECT, delete_key(<<"foo">>, ?EMPTY_JSON_OBJECT)),
    ?assertEqual(?EMPTY_JSON_OBJECT, delete_key(<<"foo">>, ?EMPTY_JSON_OBJECT, prune)),
    ?assertEqual(?EMPTY_JSON_OBJECT, delete_key([<<"foo">>], ?EMPTY_JSON_OBJECT)),
    ?assertEqual(?EMPTY_JSON_OBJECT, delete_key([<<"foo">>], ?EMPTY_JSON_OBJECT, prune)),
    ?assertEqual(?EMPTY_JSON_OBJECT, delete_key([<<"foo">>, <<"bar">>], ?EMPTY_JSON_OBJECT)),
    ?assertEqual(?EMPTY_JSON_OBJECT, delete_key([<<"foo">>, <<"bar">>], ?EMPTY_JSON_OBJECT, prune)),
    ?assertEqual(?EMPTY_JSON_OBJECT, delete_key([<<"d1k1">>], ?D7)),
    ?assertEqual(?EMPTY_JSON_OBJECT, delete_key([<<"d1k1">>], ?D7, prune)),
    ?assertEqual(?D1_AFTER_K1, delete_key([<<"d1k1">>], ?D1)),
    ?assertEqual(?D1_AFTER_K1, delete_key([<<"d1k1">>], ?D1, prune)),
    ?assertEqual(?D1_AFTER_K3_V2, delete_key([<<"d1k3">>, 2], ?D1)),
    ?assertEqual(?D1_AFTER_K3_V2, delete_key([<<"d1k3">>, 2], ?D1, prune)),
    ?assertEqual(?D6_AFTER_SUB, delete_key([<<"sub_d1">>, <<"d1k1">>], ?D6)),
    ?assertEqual(?D6_AFTER_SUB_PRUNE, delete_key([<<"sub_d1">>, <<"d1k1">>], ?D6, prune)).

-spec(get_value_test/0 :: () -> no_return()).
get_value_test() ->
    %% Basic first level key
    ?assertEqual(undefined, get_value(["d1k1"], ?EMPTY_JSON_OBJECT)),
    ?assertEqual("d1v1",    get_value(["d1k1"], ?D1)),
    ?assertEqual(undefined, get_value(["d1k1"], ?D2)),
    ?assertEqual(undefined, get_value(["d1k1"], ?D3)),
    ?assertEqual(undefined, get_value(["d1k1"], ?D4)),
    %% Basic nested key
    ?assertEqual(undefined, get_value(["sub_d1", "d1k2"], ?EMPTY_JSON_OBJECT)),
    ?assertEqual(undefined, get_value(["sub_d1", "d1k2"], ?D1)),
    ?assertEqual(d1v2,      get_value(["sub_d1", "d1k2"], ?D2)),
    ?assertEqual(undefined, get_value(["sub_d1", "d1k2"], ?D3)),
    ?assertEqual(undefined, get_value(["sub_d1", "d1k2"], ?D4)),
    %% Get the value in an object in an array in another object that is part of
    %% an array of objects
    ?assertEqual(undefined, get_value([3, "sub_docs", 2, "d2k2"], ?EMPTY_JSON_OBJECT)),
    ?assertEqual(undefined, get_value([3, "sub_docs", 2, "d2k2"], ?D1)),
    ?assertEqual(undefined, get_value([3, "sub_docs", 2, "d2k2"], ?D2)),
    ?assertEqual(undefined, get_value([3, "sub_docs", 2, "d2k2"], ?D3)),
    ?assertEqual(3.14,      get_value([3, "sub_docs", 2, "d2k2"], ?D4)),
    %% Get the value in an object in an array in another object that is part of
    %% an array of objects, but change the default return if it is not present.
    %% Also tests the ability to have indexs represented as strings
    ?assertEqual(<<"not">>, get_value([3, "sub_docs", "2", "d2k2"], [], <<"not">>)),
    ?assertEqual(<<"not">>, get_value([3, "sub_docs", "2", "d2k2"], ?D1, <<"not">>)),
    ?assertEqual(<<"not">>, get_value([3, "sub_docs", "2", "d2k2"], ?D2, <<"not">>)),
    ?assertEqual(<<"not">>, get_value([3, "sub_docs", "2", "d2k2"], ?D3, <<"not">>)),
    ?assertEqual(3.14,      get_value([3, "sub_docs", "2", "d2k2"], ?D4, <<"not">>)).

-define(T2R1, {struct, [{<<"d1k1">>, "d1v1"}, {<<"d1k2">>, <<"update">>}, {<<"d1k3">>, ["d1v3.1", "d1v3.2", "d1v3.3"]}]}).
-define(T2R2, {struct, [{<<"d1k1">>, "d1v1"}, {<<"d1k2">>, d1v2}, {<<"d1k3">>, ["d1v3.1", "d1v3.2", "d1v3.3"]}, {<<"d1k4">>, new_value}]}).
-define(T2R3, {struct, [{<<"d1k1">>, "d1v1"}, {<<"d1k2">>, {struct, [{<<"new_key">>, added_value}]}}, {<<"d1k3">>, ["d1v3.1", "d1v3.2", "d1v3.3"]}]}).
-define(T2R4, {struct, [{<<"d1k1">>, "d1v1"}, {<<"d1k2">>, d1v2}, {<<"d1k3">>, ["d1v3.1", "d1v3.2", "d1v3.3"]}, {<<"d1k4">>, {struct, [{<<"new_key">>, added_value}]}}]}).

set_value_object_test() ->
    %% Test setting an existing key
    ?assertEqual(?T2R1, set_value(["d1k2"], <<"update">>, ?D1)),
    %% Test setting a non-existing key
    ?assertEqual(?T2R2, set_value(["d1k4"], new_value, ?D1)),
    %% Test setting an existing key followed by a non-existant key
    ?assertEqual(?T2R3, set_value(["d1k2", "new_key"], added_value, ?D1)),
    %% Test setting a non-existing key followed by another non-existant key
    ?assertEqual(?T2R4, set_value(["d1k4", "new_key"], added_value, ?D1)).

-define(D5,   [{struct,[{<<"k1">>, v1}]}, {struct, [{<<"k2">>, v2}]}]).
-define(T3R1, [{struct,[{<<"k1">>,test}]},{struct,[{<<"k2">>,v2}]}]).
-define(T3R2, [{struct,[{<<"k1">>,v1},{<<"pi">>, 3.14}]},{struct,[{<<"k2">>,v2}]}]).
-define(T3R3, [{struct,[{<<"k1">>,v1},{<<"callerid">>,{struct,[{<<"name">>,"2600hz"}]}}]},{struct,[{<<"k2">>,v2}]}]).
-define(T3R4, [{struct,[{<<"k1">>,v1}]},{struct,[{<<"k2">>,"updated"}]}]).
-define(T3R5, [{struct,[{<<"k1">>,v1}]},{struct,[{<<"k2">>,v2}]},{struct,[{<<"new_key">>,"added"}]}]).

set_value_multiple_object_test() ->
    %% Set an existing key in the first json_object()
    ?assertEqual(?T3R1, set_value([1, "k1"], test, ?D5)),
    %% Set a non-existing key in the first json_object()
    ?assertEqual(?T3R2, set_value([1, "pi"], 3.14, ?D5)),
    %% Set a non-existing key followed by another non-existant key in the first json_object()
    ?assertEqual(?T3R3, set_value([1, "callerid", "name"], "2600hz", ?D5)),
    %% Set an existing key in the second json_object()
    ?assertEqual(?T3R4, set_value([2, "k2"], "updated", ?D5)),
    %% Set a non-existing key in a non-existing json_object()
    ?assertEqual(?T3R5, set_value([3, "new_key"], "added", ?D5)).

%% "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ"
-define(T4R1,  {struct, [{<<"Caller-ID">>, 1234},{list_to_binary(lists:seq(16#C0, 16#D6)), <<"Smith">>} ]}).
%% "àáâãäåæçèéêëìíîïðñòóôõö"
-define(T4R1V, {struct, [{<<"caller_id">>, 1234},{list_to_binary(lists:seq(16#E0, 16#F6)), <<"Smith">>} ]}).
%% "ØÙÚÛÜÝÞ"
-define(T5R1,  {struct, [{<<"Caller-ID">>, 1234},{list_to_binary(lists:seq(16#D8, 16#DE)), <<"Smith">>} ]}).
%% "øùúûüýþ"
-define(T5R1V, {struct, [{<<"caller_id">>, 1234},{list_to_binary(lists:seq(16#F8, 16#FE)), <<"Smith">>} ]}).

-define(T4R2,  {struct, [{<<"Account-ID">>, <<"45AHGJDF8DFDS2130S">>}, {<<"TRUNK">>, false}, {<<"Node1">>, ?T4R1 }, {<<"Node2">>, ?T4R1 }]}).
-define(T4R2V, {struct, [{<<"account_id">>, <<"45AHGJDF8DFDS2130S">>}, {<<"trunk">>, false}, {<<"node1">>, ?T4R1V}, {<<"node2">>, ?T4R1V}]}).
-define(T4R3,  {struct, [{<<"Node-1">>, {struct, [{<<"Node-2">>, ?T4R2  }] }}, {<<"Another-Node">>, ?T4R1 }] }).
-define(T4R3V, {struct, [{<<"node_1">>, {struct, [{<<"node_2">>, ?T4R2V }] }}, {<<"another_node">>, ?T4R1V}] }).



set_value_normalizer_test() ->
    %% Normalize a flat JSON object
    ?assertEqual(normalize_jobj(?T4R1), ?T4R1V),
    %% Normalize a single nested JSON object
    ?assertEqual(normalize_jobj(?T4R2), ?T4R2V),
    %% Normalize multiple nested JSON object
    ?assertEqual(normalize_jobj(?T4R3), ?T4R3V),

    ?assertEqual(normalize_jobj(?T5R1), ?T5R1V).
-endif.
