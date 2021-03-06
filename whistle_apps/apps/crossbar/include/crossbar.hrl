-include_lib("rabbitmq_erlang_client/include/amqp_client.hrl").
-include_lib("whistle/include/whistle_types.hrl").
-include_lib("whistle/include/whistle_amqp.hrl").
-include_lib("whistle/include/wh_log.hrl").
-include("crossbar_types.hrl").

-define(CONTENT_PROVIDED, [
                            {to_json, ["application/json","application/x-json"]}
                           ,{to_xml, ["application/xml"]}
			  ]).

-define(CONTENT_ACCEPTED, [
                            {from_xml, ["application/xml"]}
                           ,{from_json, ["application/json","application/x-json"]}
			   ,{from_form, ["application/x-www-form-urlencoded"]}
			   ,{from_binary, []}
			  ]).

-define(ALLOWED_METHODS, [
			   'GET'
			  ,'POST'
			  ,'PUT'
			  ,'DELETE'
                          ,'OPTIONS'
                          ,'HEAD'
			 ]).

-record(session, {
          '_id' = undefined :: binary() | undefined
	  ,'_rev' = undefined :: binary() | undefined
          ,account_id = <<>> :: binary()
          ,expires = 0 :: integer() % secs
          ,created = wh_util:current_tstamp() :: non_neg_integer() % timestamp
          ,storage = ?EMPTY_JSON_OBJECT :: json_object()
         }).

-record(cb_context, {
           content_types_provided = ?CONTENT_PROVIDED :: list(crossbar_content_handler()) | []
          ,content_types_accepted = ?CONTENT_ACCEPTED :: list(crossbar_content_handler()) | []
	  ,allowed_methods = ?ALLOWED_METHODS :: list(atom()) | []
          ,allow_methods = ?ALLOWED_METHODS :: list(atom()) | []
	  ,session = undefined :: undefined | #session{}
          ,auth_token = <<>> :: binary()
          ,auth_doc = undefined :: json_object() | undefined
          ,req_verb = <<"get">> :: binary() % <<"get">>, <<"post">>, <<"put">>, <<"delete">>, <<"head">>
          ,req_nouns = [{<<"404">>, []}] :: list(tuple(binary(), list())) | []
          ,req_json = ?EMPTY_JSON_OBJECT :: json_object() | tuple(malformed, binary())
	  ,req_files = [] :: list(tuple(binary(), json_object())) | []
          ,req_data = [] :: mochijson()
          ,account_id = <<>> :: binary()
          ,db_name = <<>> :: binary()
          ,doc = ?EMPTY_JSON_OBJECT :: json_object() | json_objects()
          ,resp_expires = {{1999,1,1},{0,0,0}}
          ,resp_etag = undefined :: undefined | automatic | string()
	  ,resp_status = error :: crossbar_status()
	  ,resp_error_msg = undefined :: json_string() | undefined
	  ,resp_error_code = undefined :: json_number() | undefined
	  ,resp_data = [] :: mochijson()
	  ,resp_headers = [] :: proplist() %% allow the modules to set headers (like Location: XXX to get a 201 response code)
	  ,start = erlang:now() :: tuple(integer(), integer(), integer())
	 }).

-ifdef(PROFILE).
-define(TIMER_START(Str), wh_timer:start(Str)).
-define(TIMER_TICK(Str), wh_timer:tick(Str)).
-define(TIMER_STOP(Str), wh_timer:stop(Str)).
-else.
-define(TIMER_START(Str), ok).
-define(TIMER_TICK(Str), ok).
-define(TIMER_STOP(Str), ok).
-endif.
