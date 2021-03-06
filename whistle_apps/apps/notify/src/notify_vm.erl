%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Handle updating devices and emails about voicemails
%%% @end
%%% Created :  3 May 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(notify_vm).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("notify.hrl").
-include_lib("callflow/include/cf_amqp.hrl").

-define(SERVER, ?MODULE).
-define(DEFAULT_VM_TEMPLATE, <<"New Voicemail Message\n\nCaller ID: {{caller_id_number}}\nCaller Name: {{caller_id_name}}\n\nCalled To: {{to_user}}   (Originally dialed number)\nCalled On: {{date_called|date:\"l, F j, Y \\a\\t H:i\"}}\n\n\nFor help or questions using your phone or voicemail, please contact support at {{support_number}} or email {{support_email}}">>).
-define(DEFAULT_SUPPORT_NUMBER, <<"(415) 886-7950">>).
-define(DEFAULT_SUPPORT_EMAIL, <<"support@2600hz.org">>).

-record(state, {amqp_q :: binary()}).

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
init([]) ->
    ?LOG_SYS("starting new vm notify process"),
    %% ensure the vm template can compile, otherwise crash the processes
    {ok, notify_vm_tmpl} = erlydtl:compile(?DEFAULT_VM_TEMPLATE, notify_vm_tmpl),
    {ok, #state{}, 0}.

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
    {reply, ok, State}.

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
handle_info(timeout, #state{amqp_q = <<>>}=State) ->
    try
	{ok, Q} = start_amqp(),
	{noreply, State#state{amqp_q=Q}}
    catch
	_:_ ->
            ?LOG_SYS("attempting to connect AMQP again in ~b ms", [?AMQP_RECONNECT_INIT_TIMEOUT]),
            {ok, _} = timer:send_after(?AMQP_RECONNECT_INIT_TIMEOUT, {amqp_reconnect, ?AMQP_RECONNECT_INIT_TIMEOUT}),
	    {noreply, State}
    end;

handle_info({amqp_reconnect, T}, State) ->
    try
	{ok, NewQ} = start_amqp(),
	{noreply, State#state{amqp_q=NewQ}}
    catch
	_:_ ->
            case T * 2 of
                Timeout when Timeout > ?AMQP_RECONNECT_MAX_TIMEOUT ->
                    ?LOG_SYS("attempting to reconnect AMQP again in ~b ms", [?AMQP_RECONNECT_MAX_TIMEOUT]),
                    {ok, _} = timer:send_after(?AMQP_RECONNECT_MAX_TIMEOUT, {amqp_reconnect, ?AMQP_RECONNECT_MAX_TIMEOUT}),
                    {noreply, State};
                Timeout ->
                    ?LOG_SYS("attempting to reconnect AMQP again in ~b ms", [Timeout]),
                    {ok, _} = timer:send_after(Timeout, {amqp_reconnect, Timeout}),
                    {noreply, State}
            end
    end;

handle_info({amqp_host_down, _}, State) ->
    ?LOG_SYS("lost AMQP connection, attempting to reconnect"),
    {ok, _} = timer:send_after(?AMQP_RECONNECT_INIT_TIMEOUT, {amqp_reconnect, ?AMQP_RECONNECT_INIT_TIMEOUT}),
    {noreply, State#state{amqp_q = <<>>}};

handle_info({#'basic.deliver'{}, #amqp_msg{props = Props, payload = Payload}}, State) when
      Props#'P_basic'.content_type == <<"application/json">> ->
    spawn(fun() ->
                  JObj = mochijson2:decode(Payload),
                  whapps_util:put_callid(JObj),
                  _ = process_req(whapps_util:get_event_type(JObj), JObj, State)
          end),
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
    ?LOG_SYS("vm notify process ~p termination", [_Reason]),
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
%% ensure the exhanges exist, build a queue, bind, and consume
%% @end
%%--------------------------------------------------------------------
-spec start_amqp/0 :: () -> tuple(ok, binary()).
start_amqp() ->
    try
        Q = amqp_util:new_queue(),
        amqp_util:bind_q_to_callevt(Q, ?NOTIFY_VOICEMAIL_NEW, other),
        amqp_util:basic_consume(Q),
        ?LOG_SYS("connected to AMQP"),
        {ok, Q}
    catch
        _:R ->
            ?LOG_SYS("failed to connect to AMQP ~p", [R]),
            {error, amqp_error}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% process the AMQP requests
%% @end
%%--------------------------------------------------------------------
-spec process_req/3 :: (MsgType, JObj, State) -> no_return() when
      MsgType :: tuple(binary(), binary()),
      JObj :: json_object(),
      State :: #state{}.
process_req({<<"conference">>, <<"new_voicemail">>}, JObj, _) ->
    true = cf_api:new_voicemail_v(JObj),
    AcctDB = wh_json:get_value(<<"Account-DB">>, JObj),
    {ok, VMBox} = couch_mgr:open_doc(AcctDB, wh_json:get_value(<<"Voicemail-Box">>, JObj)),
    {ok, UserJObj} = couch_mgr:open_doc(AcctDB, wh_json:get_value(<<"owner_id">>, VMBox)),
    case {wh_json:get_value(<<"email">>, UserJObj), wh_json:is_true(<<"vm_to_email_enabled">>, UserJObj)} of
	{undefined, _} ->
	    ?LOG_END("no email found for user ~s", [wh_json:get_value(<<"username">>, UserJObj)]);
	{_Email, false} ->
	    ?LOG_END("voicemail to email disabled for ~s", [_Email]);
	{Email, true} ->
	    {ok, AcctObj} = couch_mgr:open_doc(AcctDB, whapps_util:get_db_name(AcctDB, raw)),
	    VMTemplate = case wh_json:get_value(<<"vm_to_email_template">>, AcctObj) of
			     undefined -> notify_vm_tmpl;
			     Tmpl ->
				 try
				     {ok, notify_vm_custom_tmpl} = erlydtl:compile(Tmpl, notify_vm_custom_tmpl),
				     ?LOG("Compiled custom template"),
				     notify_vm_custom_tmpl
				 catch
				     _:E ->
					 ?LOG("Error compiling template for Acct ~s: ~p", [AcctDB, E]),
					 notify_vm_tmpl
				 end
			 end,
	    send_vm_to_email(Email, VMTemplate, JObj)
    end;
process_req(_, _, _) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% process the AMQP requests
%% @end
%%--------------------------------------------------------------------
-spec send_vm_to_email/3 :: (To, Tmpl, JObj) -> no_return() when
      To :: binary(),
      Tmpl :: notify_vm_custom_tmpl | notify_vm_tmpl,
      JObj :: json_object().
send_vm_to_email(To, Tmpl, JObj) ->
    Subject = <<"New voicemail received">>,
    {ok, Body} = format_plaintext(JObj, Tmpl),

    DB = wh_json:get_value(<<"Account-DB">>, JObj),
    Doc = wh_json:get_value(<<"Voicemail-Box">>, JObj),
    AttachmentId = wh_json:get_value(<<"Voicemail-Name">>, JObj),

    From = <<"no_reply@", (whistle_util:to_binary(net_adm:localhost()))/binary>>,

    {ok, AttachmentBin} = couch_mgr:fetch_attachment(DB, Doc, AttachmentId),

    Email = {<<"multipart">>, <<"mixed">> %% Content Type / Sub Type
		 ,[ %% Headers
		    {<<"From">>, From},
		    {<<"To">>, To},
		    {<<"Subject">>, Subject}
		  ]
	     ,[] %% Parameters
	     ,[ %% Body
		{<<"text">>, <<"plain">>, [{<<"Content-Type">>, <<"text/plain">>}], [], iolist_to_binary(Body)} %% Content Type, Subtype, Headers, Parameters, Body
		,{<<"audio">>, <<"mpeg">>
		      ,[
			{<<"Content-Disposition">>, list_to_binary([<<"attachment; filename=\"">>, AttachmentId, "\""])}
			,{<<"Content-Type">>, list_to_binary([<<"audio/mpeg; name=\"">>, AttachmentId, "\""])}
		       ]
		  ,[], AttachmentBin
		 }
	      ]
	    },
    Encoded = mimemail:encode(Email),
    SmartHost = smtp_util:guess_FQDN(),
    gen_smtp_client:send({From, [To], Encoded}, [{relay, SmartHost}]
			 ,fun(X) -> ?LOG("Sending email to ~s via ~s resulted in ~p", [To, SmartHost, X]) end).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% create a the plain text vm to email component
%% @end
%%--------------------------------------------------------------------
-spec format_plaintext/2 :: (JObj, Tmpl) -> tuple(ok, iolist()) when
      JObj :: json_object(),
      Tmpl :: notify_vm_custom_tmpl | notify_vm_tmpl.
format_plaintext(JObj, Tmpl) ->
    CIDName = wh_json:get_value(<<"Caller-ID-Name">>, JObj),
    CIDNum = wh_json:get_value(<<"Caller-ID-Number">>, JObj),
    ToE164 = whistle_util:to_e164(wh_json:get_value(<<"To-User">>, JObj)),
    DateCalled = whistle_util:to_integer(wh_json:get_value(<<"Voicemail-Timestamp">>, JObj)),

    Tmpl:render([{caller_id_number, pretty_print_did(CIDNum)}
		 ,{caller_id_name, CIDName}
		 ,{to_user, pretty_print_did(ToE164)}
		 ,{date_called, calendar:gregorian_seconds_to_datetime(DateCalled)}
		 ,{support_number, ?DEFAULT_SUPPORT_NUMBER}
		 ,{support_email, ?DEFAULT_SUPPORT_EMAIL}
		]).
%%--------------------------------------------------------------------
%% @private
%% @doc
%% create a friendly format for DIDs
%% @end
%%--------------------------------------------------------------------
-spec pretty_print_did/1 :: (DID) -> binary() when
      DID :: binary().
pretty_print_did(<<"+1", Area:3/binary, Locale:3/binary, Rest:4/binary>>) ->
    <<"1.", Area/binary, ".", Locale/binary, ".", Rest/binary>>;
pretty_print_did(<<"011", Rest/binary>>) ->
    pretty_print_did(wh_util:to_e164(Rest));
pretty_print_did(Other) ->
    Other.
