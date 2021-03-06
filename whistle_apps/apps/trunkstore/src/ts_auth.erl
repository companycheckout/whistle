%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2010-2011, VoIP INC
%%% @doc
%%% Respond to Authentication requests
%%% @end
%%% Created : 31 Aug 2010 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(ts_auth).

%% API
-export([handle_req/1]).

-include("ts.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc Give Prop, the Auth API request, create the API response JSON
%% @end
%%--------------------------------------------------------------------
-spec(handle_req/1 :: (JObj :: json_object()) -> tuple(ok, iolist()) | tuple(error, string())).
handle_req(JObj) ->
    AuthU = wh_json:get_value(<<"Auth-User">>, JObj),
    AuthR0 = wh_json:get_value(<<"Auth-Domain">>, JObj),

    %% if we're authing, it's an outbound call; no auth means carrier authed by ACL, hence inbound
    %% until we introduce IP-based auth
    Direction = <<"outbound">>,

    AuthR = case ts_util:is_ipv4(AuthR0) of
		true ->
		    [_ToUser, ToDomain] = binary:split(wh_json:get_value(<<"To">>, JObj), <<"@">>),
		    ?LOG("Auth-Realm (~s) not a hostname, trying To-Domain (~s)", [AuthR0, ToDomain]),
		    ToDomain;
		false ->
		    AuthR0
	    end,

    {ok, AuthJObj} = lookup_user(AuthU, AuthR),

    AcctID = wh_json:get_value(<<"id">>, AuthJObj),

    Defaults = [{<<"Msg-ID">>, wh_json:get_value(<<"Msg-ID">>, JObj)}
		,{<<"Custom-Channel-Vars">>, {struct, [
						       {<<"Direction">>, Direction}
						       ,{<<"Username">>, AuthU}
						       ,{<<"Realm">>, AuthR}
						       ,{<<"Account-ID">>, AcctID}
						       ,{<<"Authorizing-ID">>, AcctID}
						      ]
					     }}
		| whistle_api:default_headers(<<>> % serverID is not important, though we may want to define it eventually
					      ,wh_json:get_value(<<"Event-Category">>, JObj)
					      ,<<"authn_resp">>
					      ,?APP_NAME
					      ,?APP_VERSION)],

    response(AuthJObj, Defaults).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Inbound detection will likely be done in ACLs for carriers, so this function is more a place-holder
%% than something more meaningful. Auth will likely be bypassed for known carriers, and this function
%% will most likely return false everytime
%% -spec(is_inbound/1 :: (Domain :: binary()) -> false).
  %% is_inbound(Domain) ->
    %% IP = ts_util:find_ip(Domain),
    %% Options = [{"key", IP}],
    %% logger:format_log(info, "TS_AUTH(~p): lookup_carrier using ~p(~p) in ~p~n", [self(), Domain, IP, ?TS_VIEW_CARRIERIP]),
    %% case couch_mgr:get_results(?TS_DB, ?TS_VIEW_CARRIERIP, Options) of
    %% 	{error, not_found} ->
    %% 	    logger:format_log(info, "TS_AUTH(~p): No Carrier matching ~p(~p)~n", [self(), Domain, IP]),
    %% 	    false;
    %% 	{error,  db_not_reachable} ->
    %% 	    logger:format_log(info, "TS_AUTH(~p): No DB accessible~n", [self()]),
    %% 	    false;
    %% 	{error, view_not_found} ->
    %% 	    logger:format_log(info, "TS_AUTH(~p): View ~p missing~n", [self(), ?TS_VIEW_CARRIERIP]),
    %% 	    false;
    %% 	{ok, []} ->
    %% 	    logger:format_log(info, "TS_AUTH(~p): No Carrier matching ~p(~p)~n", [self(), Domain, IP]),
    %% 	    false;
    %% 	{ok, [{struct, ViewProp} | _Rest]} ->
    %% 	    logger:format_log(info, "TS_AUTH(~p): Carrier found for ~p(~p)~n~p~n", [self(), Domain, IP, ViewProp]),
    %% 	    true;
    %% 	_Else ->
    %% 	    logger:format_log(error, "TS_AUTH(~p): Got something unexpected during inbound check~n~p~n", [self(), _Else]),
    %% 	    false
    %% end.

-spec(lookup_user/2 :: (Name :: binary(), Realm :: binary()) -> tuple(ok, json_object()) | tuple(error, user_not_found)).
lookup_user(Name, Realm) ->
    case couch_mgr:get_results(?TS_DB, ?TS_VIEW_USERAUTHREALM, [{<<"key">>, [Realm, Name]}]) of
	{error, _}=E -> E;
	{ok, []} -> {error, user_not_found};
	{ok, [{struct, _}=User|_]} ->
	    Auth = wh_json:get_value(<<"value">>, User),
	    {ok, wh_json:set_value(<<"id">>, wh_json:get_value(<<"id">>, User), Auth)}
    end.

-spec(response/2 :: (AuthJObj :: json_object() | integer(), Prop :: proplist()) -> tuple(ok, iolist()) | tuple(error, string())).
response(?EMPTY_JSON_OBJECT, Prop) ->
    Data = lists:umerge(specific_response(403), Prop),
    whistle_api:authn_resp(Data);
response(AuthJObj, Prop) ->
    Data = lists:umerge(specific_response(AuthJObj), Prop),
    whistle_api:authn_resp(Data).

-spec(specific_response/1 :: (AuthJObj :: json_object() | integer()) -> proplist()).
specific_response({struct, _}=AuthJObj) ->
    Method = whistle_util:to_binary(string:to_lower(whistle_util:to_list(wh_json:get_value(<<"auth_method">>, AuthJObj)))),
    [{<<"Auth-Password">>, wh_json:get_value(<<"auth_password">>, AuthJObj)}
     ,{<<"Auth-Method">>, Method}
     ,{<<"Event-Name">>, <<"authn_resp">>}
     ,{<<"Access-Group">>, wh_json:get_value(<<"Access-Group">>, AuthJObj, <<"ignore">>)}
     ,{<<"Tenant-ID">>, wh_json:get_value(<<"Tenant-ID">>, AuthJObj, <<"ignore">>)}
    ];
specific_response(403) ->
    [{<<"Auth-Method">>, <<"error">>}
     ,{<<"Auth-Password">>, <<"403 Forbidden">>}
     ,{<<"Access-Group">>, <<"ignore">>}
     ,{<<"Tenant-ID">>, <<"ignore">>}].
