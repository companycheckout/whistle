%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%%
%%%
%%% Handle client requests for skel documents
%%%
%%% @end
%%% Created : 05 Jan 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cb_skels).

-behaviour(gen_server).

%% API
-export([start_link/0, create_skel/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("../../include/crossbar.hrl").

-define(SERVER, ?MODULE).

-define(VIEW_FILE, <<"views/skels.json">>).
-define(CB_LIST, <<"skels/crossbar_listing">>).
-define(GROUP_BY_SKELNAME, <<"skels/group_by_skelname">>).

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
handle_info({binding_fired, Pid, <<"v1_resource.allowed_methods.skels">>, Payload}, State) ->
    spawn(fun() ->
		  {Result, Payload1} = allowed_methods(Payload),
                  Pid ! {binding_result, Result, Payload1}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.resource_exists.skels">>, Payload}, State) ->
    spawn(fun() ->
		  {Result, Payload1} = resource_exists(Payload),
                  Pid ! {binding_result, Result, Payload1}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.validate.skels">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
		  crossbar_util:binding_heartbeat(Pid),
		  Context1 = validate(Params, Context),
		  Pid ! {binding_result, true, [RD, Context1, Params]}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.post.skels">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  Context1 = crossbar_doc:save(Context),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.put.skels">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  Context1 = crossbar_doc:save(Context),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.delete.skels">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  Context1 = crossbar_doc:delete(Context),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
	  end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"account.created">>, _Payload}, State) ->
    Pid ! {binding_result, true, ?VIEW_FILE},
    {noreply, State};

handle_info({binding_fired, Pid, _, Payload}, State) ->
    Pid ! {binding_result, false, Payload},
    {noreply, State};

handle_info(timeout, State) ->
    bind_to_crossbar(),
    whapps_util:update_all_accounts(?VIEW_FILE),
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
    _ = crossbar_bindings:bind(<<"v1_resource.allowed_methods.skels">>),
    _ = crossbar_bindings:bind(<<"v1_resource.resource_exists.skels">>),
    _ = crossbar_bindings:bind(<<"v1_resource.validate.skels">>),
    _ = crossbar_bindings:bind(<<"v1_resource.execute.#.skels">>),
    crossbar_bindings:bind(<<"account.created">>).

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
    {true, ['GET', 'PUT']};
allowed_methods([_]) ->
    {true, ['GET', 'POST', 'DELETE']};
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
validate([], #cb_context{req_verb = <<"get">>}=Context) ->
    read_skel_summary(Context);
validate([], #cb_context{req_verb = <<"put">>}=Context) ->
    create_skel(Context);
validate([SkelId], #cb_context{req_verb = <<"get">>}=Context) ->
    read_skel(SkelId, Context);
validate([SkelId], #cb_context{req_verb = <<"post">>}=Context) ->
    update_skel(SkelId, Context);
validate([SkelId], #cb_context{req_verb = <<"delete">>}=Context) ->
    read_skel(SkelId, Context);
validate(_, Context) ->
    crossbar_util:response_faulty_request(Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create a new skel document with the data provided, if it is valid
%% @end
%%--------------------------------------------------------------------
-spec create_skel/1 :: (Context) -> #cb_context{} when
      Context :: #cb_context{}.
create_skel(#cb_context{req_data=JObj}=Context) ->
    case is_valid_doc(JObj) of
        {false, Fields} ->
            crossbar_util:response_invalid_data(Fields, Context);
        {true, []} ->
            Context#cb_context{doc=wh_json:set_value(<<"pvt_type">>, <<"skel">>, JObj)
                               ,resp_status=success
                              }
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a skel document from the database
%% @end
%%--------------------------------------------------------------------
-spec(read_skel/2 :: (SkelId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
read_skel(SkelId, Context) ->
    crossbar_doc:load(SkelId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update an existing skel document with the data provided, if it is
%% valid
%% @end
%%--------------------------------------------------------------------
-spec(update_skel/2 :: (SkelId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
update_skel(SkelId, #cb_context{req_data=JObj}=Context) ->
    case is_valid_doc(JObj) of
        {false, Fields} ->
            crossbar_util:response_invalid_data(Fields, Context);
        {true, []} ->
            crossbar_doc:load_merge(SkelId, JObj, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load list of accounts, each summarized.  Or a specific
%% account summary.
%% @end
%%--------------------------------------------------------------------
-spec read_skel_summary/1 :: (Context) -> #cb_context{} when
      Context :: #cb_context{}.
read_skel_summary(Context) ->
    crossbar_doc:load_view(?CB_LIST, [], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Normalizes the resuts of a view
%% @end
%%--------------------------------------------------------------------
-spec(normalize_view_results/2 :: (Doc :: json_object(), Acc :: json_objects()) -> json_objects()).
normalize_view_results(JObj, Acc) ->
    [wh_json:get_value(<<"value">>, JObj)|Acc].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% NOTICE: This is very temporary, placeholder until the schema work is
%% complete!
%% @end
%%--------------------------------------------------------------------
-spec is_valid_doc/1 :: (JObj) -> {boolean(), [binary(),...] | []} when
      JObj :: json_object().
is_valid_doc(JObj) ->
    case wh_json:get_value(<<"default">>, JObj) of
	undefined -> {false, [<<"default">>]};
	_ -> {true, []}
    end.
