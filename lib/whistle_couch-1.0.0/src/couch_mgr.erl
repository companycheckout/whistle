%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.com>
%%% @copyright (C) 2010, James Aimonetti
%%% @doc
%%% Manage CouchDB connections
%%% @end
%%% Created : 16 Sep 2010 by James Aimonetti <james@2600hz.com>
%%%-------------------------------------------------------------------
-module(couch_mgr).

-behaviour(gen_server).

%% API
-export([start_link/0, set_host/1, set_host/3, get_host/0, get_creds/0, get_url/0]).

%% System manipulation
-export([db_exists/1, db_info/1, db_create/1, db_compact/1, db_delete/1, db_replicate/1]).

%% Document manipulation
-export([save_doc/2, open_doc/2, open_doc/3, del_doc/2, lookup_doc_rev/2]).
-export([add_change_handler/2, rm_change_handler/2, load_doc_from_file/3, update_doc_from_file/3]).

%% attachments
-export([fetch_attachment/3, put_attachment/4, put_attachment/5, delete_attachment/3]).

%% Views
-export([get_all_results/2, get_results/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-import(logger, [format_log/3]).
-import(props, [get_value/2, get_value/3]).

-include_lib("whistle/include/whistle_types.hrl"). % get the whistle types
-include_lib("couchbeam/include/couchbeam.hrl").

-define(SERVER, ?MODULE). 
-define(STARTUP_FILE, lists:concat([filename:dirname(filename:dirname(code:which(?MODULE))), "/priv/startup.config"])).

%% Host = IP Address or FQDN
%% Connection = {Host, #server{}}
%% Change handler {DBName :: string(), {Srv :: pid(), SrvRef :: reference()}
-record(state, {
	  connection = {} :: tuple(string(), #server{}) | {}
	  ,creds = {"", ""} :: tuple(string(), string()) % {User, Pass}
	  ,change_handlers = dict:new() :: dict()
	 }).

%%%===================================================================
%%% Couch Functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @public
%% @doc
%% Load a file into couch as a document (not an attachement)
%% @end
%%--------------------------------------------------------------------
-spec(load_doc_from_file/3 :: (DB :: binary(), App :: atom(), File :: list() | binary()) -> tuple(ok, json_object()) | tuple(error, term())).
load_doc_from_file(DB, App, File) ->
    Path = lists:flatten([code:priv_dir(App), "/couchdb/", whistle_util:to_list(File)]),
    logger:format_log(info, "Read into ~p from CouchDB dir: ~p~n", [DB, Path]),
    try
	{ok, Bin} = file:read_file(Path),
	?MODULE:save_doc(DB, mochijson2:decode(Bin)) %% if it crashes on the match, the catch will let us know
    catch
        _Type:{badmatch,{error,Reason}} ->
            {error, Reason};
 	_Type:Reason ->
            {error, Reason}
    end.

-spec(update_doc_from_file/3 :: (DB :: binary(), App :: atom(), File :: list() | binary()) -> tuple(ok, json_term()) | tuple(error, term())).
update_doc_from_file(DB, App, File) ->
    Path = lists:flatten([code:priv_dir(App), "/couchdb/", whistle_util:to_list(File)]),
    logger:format_log(info, "Read into ~p from CouchDB dir: ~p~n", [DB, Path]),
    try
	{ok, Bin} = file:read_file(Path),
	{struct, Prop} = mochijson2:decode(Bin),
	{ok, {struct, ExistingDoc}} = ?MODULE:open_doc(DB, props:get_value(<<"_id">>, Prop)),
	?MODULE:save_doc(DB, {struct, [{<<"_rev">>, props:get_value(<<"_rev">>, ExistingDoc)} | Prop]})
    catch        
        _Type:{badmatch,{error,Reason}} ->
            {error, Reason};
 	_Type:Reason -> 
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Detemine if a database exists
%% @end
%%--------------------------------------------------------------------
-spec(db_exists/1 :: (DbName :: binary()) -> boolean()).
db_exists(DbName) ->
    case get_conn() of
        {} -> false;
        Conn -> couchbeam:db_exists(Conn, whistle_util:to_list(DbName))
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Retrieve information regarding a database
%% @end
%%--------------------------------------------------------------------
-spec(db_info/1 :: (DbName :: binary()) -> tuple(ok, json_object()) | tuple(error, atom())).
db_info(DbName) ->
    case get_conn() of
        {} -> {error, db_not_reachable};
        Conn ->
            case couchbeam:db_info(#db{server=Conn, name=whistle_util:to_list(DbName)}) of
                {error, _Error}=E -> E;
                {ok, Info} -> {ok, prepare_doc_for_load(Info)}
            end
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Replicate a DB from one host to another
%%
%% Proplist:
%% [{<<"source">>, <<"http://some.couch.server:5984/source_db">>}
%%  ,{<<"target">>, <<"target_db">>}
%%
%%   IMPORTANT: Use the atom true, not binary <<"true">> (though it may be changing in couch to allow <<"true">>)
%%  ,{<<"create_target">>, true} % optional, creates the DB on target if non-existent
%%  ,{<<"continuous">>, true} % optional, continuously update target from source
%%  ,{<<"cancel">>, true} % optional, will cancel a replication (one-time or continuous)
%%
%%  ,{<<"filter">>, <<"source_design_doc/source_filter_name">>} % optional, filter what documents are sent from source to target
%%  ,{<<"query_params">>, {struct, [{<<"key1">>, <<"value1">>}, {<<"key2">>, <<"value2">>}]} } % optional, send params to filter function
%%  filter_fun: function(doc, req) -> boolean(); passed K/V pairs in query_params are in req in filter function
%%
%%  ,{<<"doc_ids">>, [<<"source_doc_id_1">>, <<"source_doc_id_2">>]} % optional, if you only want specific docs, no need for a filter
%%
%%  ,{<<"proxy">>, <<"http://some.proxy.server:12345">>} % optional, if you need to pass the replication via proxy to target
%%   https support for proxying is suspect
%% ].
%%
%% If authentication is needed at the source's end:
%% {<<"source">>, <<"http://user:password@some.couch.server:5984/source_db">>}
%%
%% If source or target DB is on the current connection, you can just put the DB name, e.g:
%% [{<<"source">>, <<"source_db">>}, {<<"target">>, <<"target_db">>}, ...]
%% Then you don't have to specify the auth creds (if any) for the connection
%%
%% @end
%%--------------------------------------------------------------------
-spec(db_replicate/1 :: (Prop :: tuple(struct, proplist()) | proplist()) -> tuple(ok, term()) | tuple(error, term())).
db_replicate(Prop) when is_list(Prop) ->
    db_replicate({struct, Prop});
db_replicate({struct, _}=MochiJson) ->
    case get_conn() of
	{} -> {error, server_not_reachable};
	Conn ->
	    couchbeam:replicate(Conn, prepare_doc_for_save(MochiJson))
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Detemine if a database exists
%% @end
%%--------------------------------------------------------------------
-spec(db_create/1 :: (DbName :: binary()) -> boolean()).
db_create(DbName) ->
    case get_conn() of
        {} -> false;
        Conn -> 
            case couchbeam:create_db(Conn, whistle_util:to_list(DbName)) of
                {error, _} -> false;
                {ok, _} -> true
            end
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Compact a database
%% @end
%%--------------------------------------------------------------------
-spec(db_compact/1 :: (DbName :: binary()) -> boolean()).
db_compact(DbName) ->
    case get_conn() of
        {} -> false;
        Conn ->
            case couchbeam:compact(#db{server=Conn, name=whistle_util:to_list(DbName)}) of
                {error, _} -> false;
                ok -> true
            end
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Delete a database
%% @end
%%--------------------------------------------------------------------
-spec(db_delete/1 :: (DbName :: binary()) -> boolean()).
db_delete(DbName) ->
    case get_conn() of
        {} -> false;
        Conn ->
            case couchbeam:delete_db(Conn, whistle_util:to_list(DbName)) of
                {error, _} -> false;
                {ok, _} -> true
            end
    end.

%%%===================================================================
%%% Document Functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @public
%% @doc
%% open a document given a docid returns not_found or the Document
%% @end
%%--------------------------------------------------------------------
-spec(open_doc/2 :: (DbName :: string(), DocId :: binary()) -> tuple(ok, json_object()) | tuple(error, atom())).
open_doc(DbName, DocId) ->
    open_doc(DbName, DocId, []).

-spec(open_doc/3 :: (DbName :: string(), DocId :: binary(), Options :: proplist()) -> tuple(ok, json_term()) | tuple(error, not_found | db_not_reachable)).
open_doc(DbName, DocId, Options) when not is_binary(DocId) ->
    open_doc(DbName, whistle_util:to_binary(DocId), Options);
open_doc(DbName, DocId, Options) ->    
    case get_db(DbName) of
        {error, _Error} -> {error, db_not_reachable};
	Db ->
            case couchbeam:open_doc(Db, DocId, Options) of
                {error, _Error}=E -> E;
                {ok, Doc1} -> {ok, prepare_doc_for_load(Doc1)}
            end
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% get the revision of a document (much faster than requesting the whole document)
%% @end
%%--------------------------------------------------------------------
-spec(lookup_doc_rev/2 :: (DbName :: string(), DocId :: binary()) -> tuple(error, term()) | binary()).
lookup_doc_rev(DbName, DocId) ->
    case get_db(DbName) of
	{error, _} -> {error, db_not_reachable};
	Db ->
	    case couchbeam:lookup_doc_rev(Db, DocId) of
		{error, _}=E -> E;
		Rev ->
		    binary:replace(whistle_util:to_binary(Rev), <<"\"">>, <<>>, [global])
	    end
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% save document to the db
%% @end
%%--------------------------------------------------------------------
-spec(save_doc/2 :: (DbName :: list(), Doc :: proplist() | json_object() | json_objects()) -> tuple(ok, json_object()) | tuple(ok, json_objects()) | tuple(error, atom())).
save_doc(DbName, [{struct, [_|_]}=Doc]) ->
    save_doc(DbName, Doc);
save_doc(DbName, [{struct, _}|_]=Doc) ->
    case get_db(DbName) of
	{error, _Error} -> {error, db_not_reachable};
	Db ->
            case couchbeam:save_docs(Db, prepare_doc_for_save(Doc)) of
                {error, _Error}=E -> E;
                {ok, Doc1} -> {ok, prepare_doc_for_load(Doc1)}
            end
    end;
save_doc(DbName, Doc) when is_list(Doc) ->
    save_doc(DbName, {struct, Doc});
save_doc(DbName, {struct, _}=Doc) ->
    case get_db(DbName) of
	{error, _Error} -> {error, db_not_reachable};
	Db -> 
            case couchbeam:save_doc(Db, prepare_doc_for_save(Doc)) of
                {error, _Error}=E -> E;
                {ok, Doc1} -> {ok, prepare_doc_for_load(Doc1)}
            end
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% remove document from the db
%% @end
%%--------------------------------------------------------------------
-spec(del_doc/2 :: (DbName :: list(), Doc :: proplist()) -> tuple(ok, term()) | tuple(error, atom())).
del_doc(DbName, Doc) ->
    case get_db(DbName) of
        {error, _Error} -> {error, db_not_reachable};
	Db ->
	    case couchbeam:delete_doc(Db, prepare_doc_for_save(Doc)) of
                {error, _Error}=E -> E;
                {ok, Doc1} -> {ok, prepare_doc_for_load(Doc1)}
            end
    end.

%%%===================================================================
%%% Attachment Functions
%%%===================================================================
-spec(fetch_attachment/3 :: (DbName :: string(), DocId :: binary(), AttachmentName :: binary()) -> tuple(ok, binary()) | tuple(error, term())).
fetch_attachment(DbName, DocId, AName) ->
    case get_db(DbName) of
	{error, _} -> {error, db_not_reachable};
	Db ->
	    couchbeam:fetch_attachment(Db, DocId, AName)
    end.

%% Options = [ {'content_type', Type}, {'content_length', Len}, {'rev', Rev}] <- note atoms as keys in proplist
-spec(put_attachment/4 :: (DbName :: string(), DocId :: binary(), AttachmentName :: binary(), Contents :: binary()) -> tuple(ok, binary()) | tuple(error, term())).
put_attachment(DbName, DocId, AName, Contents) ->
    put_attachment(DbName, DocId, AName, Contents, [{rev, ?MODULE:lookup_doc_rev(DbName, DocId)}]).

-spec(put_attachment/5 :: (DbName :: string(), DocId :: binary(), AttachmentName :: binary(), Contents :: binary(), Options :: proplist()) -> tuple(ok, binary()) | tuple(error, term())).
put_attachment(DbName, DocId, AName, Contents, Options) ->
    case get_db(DbName) of
	{error, _} -> {error, db_not_reachable};
	Db ->
	    couchbeam:put_attachment(Db, DocId, AName, Contents, Options)
    end.

delete_attachment(DbName, DocId, AName) ->
    delete_attachment(DbName, DocId, AName, [{rev, ?MODULE:lookup_doc_rev(DbName, DocId)}]).
delete_attachment(DbName, DocId, AName, Options) ->
    case get_db(DbName) of
	{error, _} -> {error, db_not_reachable};
	Db ->
	    couchbeam:delete_attachment(Db, DocId, AName, Options)
    end.

%%%===================================================================
%%% View Functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @public
%% @doc
%% get the results of the view
%% {Total, Offset, Meta, Rows}
%% @end
%%--------------------------------------------------------------------
-spec(get_all_results/2 :: (DbName :: list(), DesignDoc :: tuple(string(), string())) -> tuple(ok, json_object()) | tuple(ok, json_objects()) | tuple(error, atom())).
get_all_results(DbName, DesignDoc) ->
    get_results(DbName, DesignDoc, []).

-spec(get_results/3 :: (DbName :: list(), DesignDoc :: tuple(string(), string()), ViewOptions :: proplist()) -> tuple(ok, json_object()) | tuple(ok, json_objects()) | tuple(error, atom())).
get_results(DbName, DesignDoc, ViewOptions) ->
    case get_db(DbName) of
	{error, _Error} -> {error, db_not_reachable};
	Db ->
	    case get_view(Db, DesignDoc, ViewOptions) of
		{error, _Error}=E -> E;
		View ->
		    case couchbeam_view:fetch(View) of
			{ok, {Prop}} ->
			    Rows = get_value(<<"rows">>, Prop, []),
                            {ok, prepare_doc_for_load(Rows)};
			{error, _Error}=E -> E
		    end
	    end
    end.

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
-spec(start_link/0 :: () -> tuple(ok, pid()) | ignore | tuple(error, term())).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% set the host to connect to
-spec(set_host/1 :: (HostName :: string()) -> ok | tuple(error, term())).
set_host(HostName) ->
    set_host(HostName, "", "").

set_host(HostName, UserName, Password) ->
    gen_server:call(?MODULE, {set_host, HostName, UserName, Password}, infinity).

get_host() ->
    gen_server:call(?MODULE, get_host).

get_creds() ->
    gen_server:call(?MODULE, {get_creds}).

get_conn() ->
    gen_server:call(?MODULE, {get_conn}).

get_db(DbName) ->
    Conn = gen_server:call(?MODULE, {get_conn}),
    open_db(whistle_util:to_list(DbName), Conn).

get_url() ->
    case {whistle_util:to_binary(get_host()), get_creds()} of 
        {<<"">>, _} -> 
            undefined;
        {H, {[], []}} ->
            <<"http://", H/binary, ":5984", $/>>;
        {H, {User, Pwd}} ->
            U = whistle_util:to_binary(User),
            P = whistle_util:to_binary(Pwd),
            <<"http://", U/binary, $:, P/binary, $@, H/binary, ":5984", $/>>
    end.

add_change_handler(DBName, DocID) ->
    gen_server:call(?MODULE, {add_change_handler, whistle_util:to_list(DBName), whistle_util:to_binary(DocID)}).

rm_change_handler(DBName, DocID) ->
    gen_server:call(?MODULE, {rm_change_handler, whistle_util:to_list(DBName), whistle_util:to_binary(DocID)}).

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
-spec(init/1 :: (Args :: list()) -> tuple(ok, tuple())).
init(_) ->
    process_flag(trap_exit, true),
    {ok, init_state()}.

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
handle_call(get_host, _From, #state{connection={H,_}}=State) ->
    {reply, H, State};
handle_call({set_host, Host, User, Pass}, _From, #state{connection={OldHost, _}}=State) ->
    format_log(info, "WHISTLE_COUCH(~p): Updating host from ~p to ~p~n", [self(), OldHost, Host]),
    case get_new_connection(Host, User, Pass) of
	{error, _Error}=E ->
	    {reply, E, State};
	HC ->
	    {reply, ok, State#state{connection=HC, change_handlers=dict:new(), creds={User,Pass}}}
    end;
handle_call({set_host, Host, User, Pass}, _From, State) ->
    format_log(info, "WHISTLE_COUCH(~p): Setting host for the first time to ~p~n", [self(), Host]),
    case get_new_connection(Host, User, Pass) of
	{error, _Error}=E ->
	    {reply, E, State};
	{_Host, _Conn}=HC ->
	    {reply, ok, State#state{connection=HC, change_handlers=dict:new(), creds={User,Pass}}}
    end;
handle_call({get_conn}, _, #state{connection={_Host, Conn}}=State) ->
    {reply, Conn, State};
handle_call({get_creds}, _, #state{creds=Cred}=State) ->
    {reply, Cred, State};
handle_call({add_change_handler, DBName, DocID}, {Pid, _Ref}, #state{change_handlers=CH, connection={_,Conn}}=State) ->
    case dict:find(DBName, CH) of
	{Srv, _} ->
	    change_handler:add_listener(Srv, Pid, DocID),
	    {reply, ok, State};
	error ->
	    {ok, Srv} = change_mgr_sup:start_handler(open_db(whistle_util:to_list(DBName), Conn), []),
	    SrvRef = erlang:monitor(process, Srv),
	    change_handler:add_listener(Srv, Pid, DocID),
	    {reply, ok, State#state{change_handlers=dict:store(DBName, {Srv, SrvRef}, CH)}}
    end;
handle_call({rm_change_handler, DBName, DocID}, {Pid, _Ref}, #state{change_handlers=CH}=State) ->
    case dict:find(DBName, CH) of
	{Srv, _} -> change_handler:rm_listener(Srv, Pid, DocID);
	error -> ok
    end,
    {reply, ok, State};
handle_call(Req, From, #state{connection={}}=State) ->
    format_log(info, "WHISTLE_COUCH(~p): No connection, trying localhost(~p) with no auth~n", [self(), net_adm:localhost()]),
    case get_new_connection(net_adm:localhost(), "", "") of
	{error, _Error}=E ->
	    {reply, E, State};
	{_Host, _Conn}=HC ->
	    handle_call(Req, From, State#state{connection=HC, change_handlers=dict:new()})
    end;
handle_call(_Request, _From, State) ->
    format_log(error, "WHISTLE_COUCH(~p): Failed call ~p with state ~p~n", [self(), _Request, State]),
    {reply, {error, unhandled_call}, State}.

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
handle_info({'DOWN', Ref, process, Srv, complete}, #state{change_handlers=CH}=State) ->
    format_log(error, "WHISTLE_COUCH(~p): Srv ~p down after complete~n", [self(), Srv]),
    erlang:demonitor(Ref, [flush]),
    {noreply, State#state{change_handlers=remove_ref(Ref, CH)}};
handle_info({'DOWN', Ref, process, Srv, {error,connection_closed}}, #state{change_handlers=CH}=State) ->
    format_log(error, "WHISTLE_COUCH(~p): Srv ~p down after conn closed~n", [self(), Srv]),
    erlang:demonitor(Ref, [flush]),
    {noreply, State#state{change_handlers=remove_ref(Ref, CH)}};
handle_info(_Info, State) ->
    format_log(error, "WHISTLE_COUCH(~p): Unexpected info ~p~n", [self(), _Info]),
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
%% @end
%%--------------------------------------------------------------------
-spec(get_new_connection/3 :: (Host :: string(), User :: string(), Pass :: string()) -> tuple(string(), #server{}) | tuple(error, term())).
get_new_connection(Host, "", "") -> get_new_conn(Host, []);
get_new_connection(Host, User, Pass) -> get_new_conn(Host, [{basic_auth, {User, Pass}}]).

-spec(get_new_conn/2 :: (Host :: string(), Opts :: proplist()) -> tuple(string(), #server{}) | tuple(error, term())).
get_new_conn(Host, Opts) ->
    Conn = couchbeam:server_connection(Host, 5984, "", Opts),
    format_log(info, "WHISTLE_COUCH(~p): Host ~p Opts ~p has conn ~p~n", [self(), Host, Opts, Conn]),
    case couchbeam:server_info(Conn) of
	{ok, _Version} ->
	    format_log(info, "WHISTLE_COUCH(~p): Connected to ~p~n~p~n", [self(), Host, _Version]),
	    spawn(fun() ->
			  case props:get_value(basic_auth, Opts) of
			      undefined -> save_config(Host);
			      {U, P} -> save_config(Host, U, P)
			  end
		  end),
	    {Host, Conn};
	{error, Err}=E ->
	    format_log(error, "WHISTLE_COUCH(~p): Unable to connect to ~p: ~p~n", [self(), Host, Err]),
	    E
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% open_db, if DbName is known, returns the {#db{}, DBs}, else returns {#db{}, [{DbName, #db{}} | DBs]}
%% an error in opening the db will cause a {{error, Err}, DBs} to be returned
%% @end
%%--------------------------------------------------------------------
-spec(open_db/2 :: (DbName :: string(), Conn :: #server{}) -> tuple(error, db_not_reachable) | #db{}).
open_db(DbName, Conn) -> 
    case couchbeam:open_or_create_db(Conn, DbName) of
        {error, _Error}=E -> E;
        {ok, Db} ->
            case couchbeam:db_info(Db) of
                {error, _Error}=E -> E;
                {ok, _JSON} -> Db
            end
    end.
    
%%--------------------------------------------------------------------
%% @private
%% @doc
%% get_view, if Db/DesignDoc is known, return {#view{}, Views},
%% else returns {#view{}, [{{#db{}, DesignDoc, ViewOpts}, #view{}} | Views]}
%% @end
%%--------------------------------------------------------------------    
-spec(get_view/3 :: (Db :: #db{}, DesignDoc :: string() | tuple(string(), string()), ViewOptions :: list()) -> #view{} | tuple(error, view_not_found)).
get_view(Db, DesignDoc, ViewOptions) ->
    case couchbeam:view(Db, DesignDoc, ViewOptions) of
	{error, _Error}=E -> E;
	{ok, View} -> View
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(init_state/0 :: () -> #state{}).
init_state() ->
    case get_startup_config() of
	{ok, Ts} ->
	    {_, Host, User, Pass} = case lists:keyfind(couch_host, 1, Ts) of
					false ->
					    case lists:keyfind(default_couch_host, 1, Ts) of
						false -> {ok, net_adm:localhost(), "", ""};
						H -> H
					    end;
					H -> H
				    end,
	    case get_new_connection(Host, User, Pass) of
		{error, _} -> #state{};
		{Host, _}=C -> #state{connection=C}
	    end;
	_ -> #state{}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(get_startup_config/0 :: () -> tuple(ok, proplist()) | tuple(error, term())).
get_startup_config() ->
    file:consult(?STARTUP_FILE).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(save_config/1 :: (H :: string()) -> no_return()).
save_config(H) ->
    save_config(H, "", "").

save_config(H, U, P) ->
    {ok, Config} = get_startup_config(),
    file:write_file(?STARTUP_FILE
		    ,lists:foldl(fun(Item, Acc) -> [io_lib:format("~p.~n", [Item]) | Acc] end
				 , "", [{couch_host, H, U, P} | lists:keydelete(couch_host, 1, Config)])
		   ).

prepare_doc_for_save([{struct, _}|_]=Doc) ->
    lists:map(fun(D) -> prepare_doc_for_save(D) end, Doc);
prepare_doc_for_save({struct, _}=Doc) ->
    couchbeam_util:json_decode(mochijson2:encode(Doc));
prepare_doc_for_save(BinDoc) when is_binary(BinDoc) ->
    couchbeam_util:json_decode(BinDoc);
prepare_doc_for_save({_}=Doc) ->
    Doc.

prepare_doc_for_load([]) -> [];
prepare_doc_for_load({struct, _}=Doc)->
    Doc;
prepare_doc_for_load([{struct, _}|_]=Docs) ->
    Docs;
prepare_doc_for_load([{_}|_]=Docs) ->
    lists:map(fun prepare_doc_for_load/1, Docs);
prepare_doc_for_load(BinDoc) when is_binary(BinDoc) ->
    mochijson2:decode(BinDoc);
prepare_doc_for_load({_}=Doc) ->
    mochijson2:decode(couchbeam_util:json_encode(Doc)).

-spec(remove_ref/2 :: (Ref :: reference(), CH :: dict()) -> dict()).
remove_ref(Ref, CH) ->
    dict:filter(fun(_, {_, Ref1}) when Ref1 =:= Ref -> false;
		   (_, _) -> true end, CH).
