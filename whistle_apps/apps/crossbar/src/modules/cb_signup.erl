%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Signup module
%%%
%%% Handle client requests for new account on-boarding.  This is a
%%% special, one-off module because:
%%%
%%% * it authenticates and authorizes itself
%%% * it has a completely unique role
%%% * it operates without an account id (or account db)
%%% * it breaks the REST API (prefoming a GET on the confirmation link
%%%           has significant side-effects)
%%%
%%% @end
%%% Created : 22 Apr 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cb_signup).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("../../include/crossbar.hrl").
-include_lib("webmachine/include/webmachine.hrl").

-define(SERVER, ?MODULE).

-define(SIGNUP_DB, <<"signups">>).

-define(VIEW_FILE, <<"views/signup.json">>).
-define(VIEW_ACTIVATION_KEYS, <<"signups/listing_by_key">>).
-define(VIEW_ACTIVATION_REALM, <<"signups/group_by_realm">>).
-define(VIEW_ACTIVATION_NOT_EXPIRED, <<"signups/has_not_expired">>).

-define(CLEANUP_INTERVAL, 1000 * 3600 * 24). % once a day (in milliseconds)
-define(SIGNUP_LIFESPAN, 3600*24*7). % a week (in seconds)

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(_) ->
    {ok, ok, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({binding_fired, Pid, <<"v1_resource.authorize">>, {RD, #cb_context{req_nouns=[{<<"signup">>,[]}]}=Context}}, State) ->
    Pid ! {binding_result, true, {RD, Context}},
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.authorize">>, {RD, #cb_context{req_nouns=[{<<"signup">>,[_]}]}=Context}}, State) ->
    Pid ! {binding_result, true, {RD, Context}},
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.authenticate">>, {RD, #cb_context{req_nouns=[{<<"signup">>,[]}]}=Context}}, State) ->
    Pid ! {binding_result, true, {RD, Context}},
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.authenticate">>, {RD, #cb_context{req_nouns=[{<<"signup">>,[_]}]}=Context}}, State) ->
    Pid ! {binding_result, true, {RD, Context}},
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.allowed_methods.signup">>, Payload}, State) ->
    spawn(fun() ->
		  {Result, Payload1} = allowed_methods(Payload),
                  Pid ! {binding_result, Result, Payload1}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.resource_exists.signup">>, Payload}, State) ->
    spawn(fun() ->
		  {Result, Payload1} = resource_exists(Payload),
                  Pid ! {binding_result, Result, Payload1}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.validate.signup">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  crossbar_util:binding_heartbeat(Pid),
                  Context1 = validate(Params, Context#cb_context{db_name=?SIGNUP_DB}),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.get.signup">>, [RD, #cb_context{doc=JObj}=Context | [_]=Params]}, State) ->
    spawn(fun() ->
                  crossbar_util:binding_heartbeat(Pid),

                  Event1 = <<"v1_resource.execute.put.accounts">>,
                  Payload1 = [RD, Context#cb_context{doc=wh_json:get_value(<<"account">>, JObj)}, [[]]],
                  [_, #cb_context{resp_status=success}=Context1 | _] = crossbar_bindings:fold(Event1, Payload1),

                  Event2 = <<"v1_resource.execute.put.users">>,
                  Payload2 = [RD, Context1#cb_context{doc=wh_json:get_value(<<"user">>, JObj)}, [[]]],
                  crossbar_bindings:fold(Event2, Payload2),

                  _ = crossbar_doc:delete(Context),

                  Pid ! {binding_result, true, [RD, Context1, Params]}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.put.signup">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  Context1 = crossbar_doc:save(Context#cb_context{db_name=?SIGNUP_DB}),
                  Pid ! {binding_result, true, [RD, Context1, Params]},
                  confirmation_email(RD, Context1)
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, _, Payload}, State) ->
    Pid ! {binding_result, false, Payload},
    {noreply, State};

handle_info(cleanup, State) ->
    logger:format_log(info, ">>> CLEANING", []),
    cleanup_signups(),
    logger:format_log(info, ">>> DONE", [] ),
    {noreply, State};

handle_info(timeout, State) ->
    bind_to_crossbar(),
    couch_mgr:db_create(?SIGNUP_DB),
    case couch_mgr:update_doc_from_file(?SIGNUP_DB, crossbar, ?VIEW_FILE) of
        {error, _} ->
            couch_mgr:load_doc_from_file(?SIGNUP_DB, crossbar, ?VIEW_FILE);
        {ok, _} -> ok
    end,
    timer:send_interval(?CLEANUP_INTERVAL, cleanup),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function binds this server to the crossbar bindings server,
%% for the keys we need to consume.
%% @end
%%--------------------------------------------------------------------
-spec(bind_to_crossbar/0 :: () ->  no_return()).
bind_to_crossbar() ->
    _ = crossbar_bindings:bind(<<"v1_resource.authenticate">>),
    _ = crossbar_bindings:bind(<<"v1_resource.authorize">>),
    _ = crossbar_bindings:bind(<<"v1_resource.allowed_methods.signup">>),
    _ = crossbar_bindings:bind(<<"v1_resource.resource_exists.signup">>),
    _ = crossbar_bindings:bind(<<"v1_resource.validate.signup">>),
    crossbar_bindings:bind(<<"v1_resource.execute.#.signup">>).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec(allowed_methods/1 :: (Paths :: list()) -> tuple(boolean(), http_methods())).
allowed_methods([]) ->
    {true, ['PUT']};
allowed_methods([_]) ->
    {true, ['GET']};
allowed_methods(_) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec(resource_exists/1 :: (Paths :: list()) -> tuple(boolean(), [])).
resource_exists([]) ->
    {true, []};
resource_exists([_]) ->
    {true, []};
resource_exists(_) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec(validate/2 :: (Params :: list(), Context :: #cb_context{}) -> #cb_context{}).
validate([], #cb_context{req_verb = <<"put">>}=Context) ->
    signup_new_account(Context);
validate([ActivationKey], #cb_context{req_verb = <<"get">>}=Context) ->
    check_activation_key(ActivationKey, Context);
validate(_, Context) ->
    crossbar_util:response_faulty_request(Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create a new signup document with the data provided, if it is valid
%% @end
%%--------------------------------------------------------------------
-spec(signup_new_account/1 :: (Context :: #cb_context{}) -> #cb_context{}).
signup_new_account(#cb_context{req_data=JObj}=Context) ->
    case is_valid_doc(JObj) of
        {false, Fields} ->
            crossbar_util:response_invalid_data(Fields, Context);
        {true, _} ->
            create_activation_request(Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a signup document from the database
%% @end
%%--------------------------------------------------------------------
-spec(check_activation_key/2 :: (ActivationKey :: binary(), Context :: #cb_context{}) -> #cb_context{}).
check_activation_key(ActivationKey, Context) ->
    case crossbar_doc:load_view(?VIEW_ACTIVATION_KEYS, [{<<"key">>, ActivationKey}], Context#cb_context{db_name=?SIGNUP_DB}) of
        #cb_context{resp_status=success, doc=[JObj|_]} ->
            Context#cb_context{resp_status=success, doc=wh_json:get_value(<<"value">>, JObj)};
        #cb_context{resp_status=success, doc=JObj} when JObj =/= [] ->
            Context#cb_context{resp_status=success, doc=wh_json:get_value(<<"value">>, JObj)};
        _ ->
            crossbar_util:response(error, <<"invalid activation key">>, 403, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% NOTICE: This is very temporary, placeholder until the schema work is
%% complete!
%% @end
%%--------------------------------------------------------------------
-spec(is_valid_doc/1 :: (JObj :: json_object()) -> tuple(boolean(), list(binary()))).
is_valid_doc(JObj) ->
    {(wh_json:get_value(<<"pvt_user">>, JObj) =/= undefined), [<<"">>]}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(create_activation_request/1 :: (Context :: #cb_context{}) -> #cb_context{}).
create_activation_request(#cb_context{req_data=JObj}=Context) ->
    case users:create_user(Context#cb_context{req_data=wh_json:get_value(<<"user">>, JObj, ?EMPTY_JSON_OBJECT)}) of
	#cb_context{resp_status=success, doc=User} ->
	    AcctObj = wh_json:get_value(<<"account">>, JObj, ?EMPTY_JSON_OBJECT),
	    case is_unique_realm(Context, wh_json:get_value(<<"realm">>, AcctObj)) andalso accounts:create_account(Context#cb_context{req_data=AcctObj}) of
		false ->
		    crossbar_util:response_invalid_data([<<"realm">>], Context);
		#cb_context{resp_status=success, doc=Account}=Context1 ->
		    Context1#cb_context{doc={struct, [
						      {<<"pvt_user">>, User}
						      ,{<<"pvt_account">>, Account}
						      ,{<<"has_expired">>, false }
						      ,{<<"pvt_activation_key">>, create_activation_key()}
						     ]}};
		Context1 -> Context1
	    end;
	Context1 -> Context1
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(create_activation_key/0 :: () -> binary()).
create_activation_key() ->
     whistle_util:to_binary(whistle_util:to_hex(crypto:rand_bytes(32))).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(confirmation_email/2 :: (RD :: #wm_reqdata{}, Context :: #cb_context{}) -> no_return()).
confirmation_email(RD, #cb_context{doc=JObj}) ->
    Port = case wrq:port(RD) of
	       80 -> "";
	       P -> [":", whistle_util:to_list(P)]
	   end,
    Host = ["http://", string:join(lists:reverse(wrq:host_tokens(RD)), "."), Port, "/"],
    send_confirmation_email(
       wh_json:get_value([<<"pvt_user">>, <<"email">>], JObj)
      ,wh_json:get_value([<<"pvt_user">>, <<"first_name">>], JObj)
      ,wh_json:get_value([<<"pvt_user">>, <<"last_name">>], JObj)
      ,<<(whistle_util:to_binary(Host))/binary>>
      ,wh_json:get_value(<<"pvt_activation_key">>, JObj, <<>>)
     ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(send_confirmation_email/5 :: (Email :: binary(), First :: binary(), Last :: binary()
                                    ,BaseURL :: binary(), Key :: binary()) -> no_return()).
send_confirmation_email(Email, First, Last, BaseURL, Key) ->
    Cmd = whistle_util:to_list(<<(whistle_util:to_binary(code:priv_dir(crossbar)))/binary
                                 ,"/confirmation_email.sh"
                                 ,$ , $", Email/binary, $"
                                 ,$ , $", First/binary, $"
                                 ,$ , $", Last/binary, $"
                                 ,$ , $", BaseURL/binary, $"
                                 ," \"v1/signup/\""
                                 ,$ , $", Key/binary, $"
                               >>),
    os:cmd(Cmd).

is_unique_realm(_, undefined) -> false;
is_unique_realm(Context, Realm) ->
    V = case crossbar_doc:load_view(?VIEW_ACTIVATION_REALM, [{<<"key">>, Realm}
							     ,{<<"reduce">>, <<"true">>}
							    ]
				    ,Context#cb_context{db_name=?SIGNUP_DB}) of
	    #cb_context{resp_status=success, doc=[J]} -> wh_json:get_value(<<"value">>, J, []);
	    #cb_context{resp_status=success, doc=[]} -> []
	end,
    is_unique_realm1(Realm, V).

is_unique_realm1(undefined, [_]) -> false;
is_unique_realm1(undefined, []) -> false;
is_unique_realm1(_, []) -> true;
is_unique_realm1(Realm, [Realm]) -> true;
is_unique_realm1(_, _) -> false.


cleanup_signups() ->
    logger:format_log(info, "---- Cleaning old registrations ...", []),
    {ok, Docs} = couch_mgr:get_results(?SIGNUP_DB, ?VIEW_ACTIVATION_NOT_EXPIRED, [{<<"include_docs">>, true}]),
    Now = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
    Fun = fun(Doc) -> check_for_expiration(wh_json:get_value(<<"doc">>, Doc), Now) end,
    lists:foreach(Fun, Docs),

    logger:format_log(info, "----- Registrations cleaned", []).

check_for_expiration(Doc, Now) ->
    logger:format_log(info, "---- Checking for registrations for ID:~p", [wh_json:get_value([<<"pvt_user">>, <<"email">>], Doc)]),

    NewDoc = wh_json:set_value( <<"pvt_has_expired">>, is_expired( wh_json:get_value( <<"pvt_created">>, Doc ), Now ), Doc ),
    case couch_mgr:save_doc(?SIGNUP_DB, NewDoc) of
	{error, conflict} ->
	    check_for_expiration(couch_mgr:load_doc(?SIGNUP_DB, wh_json:get_value(<<"_id">>, NewDoc)), Now);
	{ok, _} ->
	    ok;
	{_,_} ->
	    error
    end.

is_expired(Timestamp, Now) ->
    Timestamp < (Now + ?SIGNUP_LIFESPAN).
