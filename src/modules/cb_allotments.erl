%%%-------------------------------------------------------------------
%%% @copyright
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Dinkor Media Group (Sergey Korobkov)
%%%-------------------------------------------------------------------
-module(cb_allotments).

-export([init/0
         ,allowed_methods/0, allowed_methods/1
         ,resource_exists/0, resource_exists/1
         ,validate/1, validate/2
         ,post/1
        ]).

-export([is_allowed/1]).

-include("../crossbar.hrl").
-include_lib("whistle/src/wh_json.hrl").

-define(LIST_CONSUMED, <<"allotments/consumed">>).
-define(PVT_TYPE, <<"limits">>).
-define(CONSUMED, <<"consumed">>).
-define(PVT_ALLOTMENTS, <<"pvt_allotments">>).

%%%===================================================================
%%% API
%%%===================================================================
init() ->
    _ = crossbar_bindings:bind(<<"*.allowed_methods.allotments">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"*.resource_exists.allotments">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"*.validate.allotments">>, ?MODULE, 'validate'),
   crossbar_bindings:bind(<<"*.execute.post.allotments">>, ?MODULE, 'post').

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods() -> http_methods().
allowed_methods() ->
    [?HTTP_GET, ?HTTP_POST].

allowed_methods(?CONSUMED) ->
    [?HTTP_GET].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec resource_exists() -> 'true'.
-spec resource_exists(path_token()) -> 'true'.
resource_exists() -> 'true'.
resource_exists(?CONSUMED) -> 'true'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate(cb_context:context()) -> cb_context:context().
validate(Context) ->
    validate_allotments(Context, cb_context:req_verb(Context)).

-spec validate(cb_context:context(), path_token()) -> cb_context:context().
validate(Context, ?CONSUMED) ->
    validate_consumed(Context, cb_context:req_verb(Context)).

-spec validate_allotments(cb_context:context(), http_method()) -> cb_context:context().
validate_allotments(Context, ?HTTP_GET) ->
    load_allotments(Context);
validate_allotments(Context, ?HTTP_POST) ->
    cb_context:validate_request_data(<<"allotments">>, Context, fun on_successful_validation/1).

-spec validate_consumed(cb_context:context(), http_method()) -> cb_context:context().
validate_consumed(Context, ?HTTP_GET) ->
    load_consumed(Context).

-spec post(cb_context:context()) -> cb_context:context().
post(Context) ->
    update_allotments(Context).

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a document from the database
%% @end
%%--------------------------------------------------------------------
-spec load_allotments(cb_context:context()) -> cb_context:context().
load_allotments(Context) ->
    Context1 = maybe_handle_load_failure(crossbar_doc:load(?PVT_TYPE, Context)),
    Allotments = wh_json:get_json_value(?PVT_ALLOTMENTS, cb_context:doc(Context1), wh_json:new()),
    cb_context:set_resp_data(Context1, Allotments).


-spec load_consumed(cb_context:context()) -> cb_context:context().
load_consumed(Context) ->
    Context1 = crossbar_doc:load(?PVT_TYPE, Context),
    Allotments = wh_json:get_json_value(?PVT_ALLOTMENTS, cb_context:doc(Context1), wh_json:new()),
    MoDb = cb_context:account_modb(Context),
    load_consumed(Context, MoDb, Allotments).

-spec load_consumed(cb_context:context(), api_binary(), wh_json:objects()) -> cb_context:context().
load_consumed(Context, MoDb, Allotments) ->
    {_, Result} = wh_json:foldl(fun foldl_consumed/3, {MoDb, []}, Allotments),
    cb_context:setters(Context
                       ,[{fun cb_context:set_resp_status/2, 'success'}
                         ,{fun cb_context:set_resp_data/2, Result}
                        ]).

-spec foldl_consumed(api_binary(), wh_json:object(), {cb_context:context(), api_binary(), wh_json:objects()}) -> wh_json:objects().
foldl_consumed(Classification, Value, {MoDb, Acc}) ->
    Cycle = wh_json:get_value(<<"cycle">>, Value),
    CycleStart = cycle_start(Cycle),
    CycleEnd = cycle_end(Cycle),
    ViewOptions = [{'startkey', [Classification, CycleStart]}
                   ,{'endkey', [Classification, CycleEnd]}
                   ,{'reduce', 'true'}
                  ],
    case couch_mgr:get_results(MoDb, ?LIST_CONSUMED, ViewOptions) of
        {'ok', [Result]} -> 
            R = wh_json:from_list(
                  [{Classification, 
                    wh_json:from_list(
                      [{<<"cycle">>, Cycle}
                       ,{<<"cycle_start">>, CycleStart}
                       ,{<<"cycle_end">>, CycleEnd}
                       ,{<<"consumed">>, wh_json:get_value(<<"value">>, Result)}
                      ]
                     )
                   }]
                 ), 
            {MoDb, [ R | Acc]};
        {'ok', []} -> {MoDb, Acc};
        {'error', _} ->{MoDb, Acc} 
    end.

-spec on_successful_validation(cb_context:context()) -> cb_context:context().
on_successful_validation(Context) ->
    case is_allowed(Context) of
        'true' -> maybe_handle_load_failure(crossbar_doc:load(?PVT_TYPE, Context));
        'false' -> crossbar_util:response_400("sub-accounts of non-master resellers must contact the reseller to change their allotments", wh_json:new(), Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec is_allowed(cb_context:context()) -> boolean().
is_allowed(Context) ->
    AccountId = cb_context:account_id(Context),
    AuthAccountId = cb_context:auth_account_id(Context),
    IsSystemAdmin = wh_util:is_system_admin(AuthAccountId),
    {'ok', MasterAccount} = whapps_util:get_master_account_id(),
    case wh_services:find_reseller_id(AccountId) of
        AuthAccountId ->
            lager:debug("allowing reseller to update allotments"),
            'true';
        MasterAccount ->
            lager:debug("allowing direct account to update allotments"),
            'true';
        _Else when IsSystemAdmin ->
            lager:debug("allowing system admin to update allotments"),
            'true';
        _Else ->
            lager:debug("sub-accounts of non-master resellers must contact the reseller to change their allotments"),
            'false'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec maybe_handle_load_failure(cb_context:context()) ->
                                       cb_context:context().
-spec maybe_handle_load_failure(cb_context:context(), pos_integer()) ->
                                       cb_context:context().
maybe_handle_load_failure(Context) ->
    maybe_handle_load_failure(Context, cb_context:resp_error_code(Context)).

maybe_handle_load_failure(Context, 404) ->
    Data = cb_context:req_data(Context),
    NewLimits = wh_json:from_list([{<<"pvt_type">>, ?PVT_TYPE}
                                   ,{<<"_id">>, ?PVT_TYPE}
                                  ]),
    JObj = wh_json_schema:add_defaults(wh_json:merge_jobjs(NewLimits, wh_json:public_fields(Data))
                                       ,<<"limits">>
                                      ),

    cb_context:setters(Context
                       ,[{fun cb_context:set_resp_status/2, 'success'}
                         ,{fun cb_context:set_resp_data/2, wh_json:public_fields(JObj)}
                         ,{fun cb_context:set_doc/2, crossbar_doc:update_pvt_parameters(JObj, Context)}
                        ]);
maybe_handle_load_failure(Context, _RespCode) -> Context.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec update_allotments(cb_context:context()) -> cb_context:context().
update_allotments(Context) ->
    Doc = cb_context:doc(Context),
    Allotments = cb_context:req_data(Context),
    NewDoc = wh_json:set_value(?PVT_ALLOTMENTS, Allotments, Doc),
    Context1 = crossbar_doc:save(cb_context:set_doc(Context, NewDoc)),
    cb_context:set_resp_data(Context1, Allotments).

-spec cycle_start(ne_binary()) -> integer().
cycle_start(<<"monthly">>) ->
    {{Year, Month, _}, _} = calendar:universal_time(),
    calendar:datetime_to_gregorian_seconds({{Year, Month, 1}, {0, 0, 0}});
cycle_start(<<"weekly">>) ->
    {Date, _} = calendar:universal_time(),
    calendar:datetime_to_gregorian_seconds({Date, {0, 0, 0}}) -
        (calendar:day_of_the_week(Date) - 1) * ?SECONDS_IN_DAY;
cycle_start(<<"daily">>) ->
    {{Year, Month, Day}, _} = calendar:universal_time(),
    calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {0, 0, 0}});
cycle_start(<<"hourly">>) ->
    {{Year, Month, Day}, {Hour, _, _}} = calendar:universal_time(),
    calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {Hour, 0, 0}});
cycle_start(<<"minutely">>) ->
    {{Year, Month, Day}, {Hour, Min, _}} = calendar:universal_time(),
    calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {Hour, Min, 0}}).

-spec cycle_end(ne_binary()) -> integer().
cycle_end(<<"monthly">>) -> 
    {{Year, Month, _}, _} = calendar:universal_time(),
    LastDay = calendar:last_day_of_the_month(Year, Month),
    calendar:datetime_to_gregorian_seconds({{Year, Month, LastDay}, {23, 59, 59}}) + 1;
cycle_end(<<"weekly">>) -> cycle_start(<<"weekly">>) + ?SECONDS_IN_WEEK;
cycle_end(<<"daily">>) ->  cycle_start(<<"daily">>) + ?SECONDS_IN_DAY;
cycle_end(<<"hourly">>) -> cycle_start(<<"hourly">>) + ?SECONDS_IN_HOUR;
cycle_end(<<"minutely">>) -> cycle_start(<<"minutely">>) + ?SECONDS_IN_MINUTE.
