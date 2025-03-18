%%%----------------------------------------------------------------------
%%% File    : mod_pubsub_serverinfo.erl
%%% Author  : Guus der Kinderen <guus.der.kinderen@gmail.com>
%%% Purpose : Exposes server information over Pub/Sub
%%% Created : 26 Dec 2023 by Guus der Kinderen <guus.der.kinderen@gmail.com>
%%%
%%%
%%% ejabberd, Copyright (C) 2023   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_pubsub_serverinfo).
-author('guus.der.kinderen@gmail.com').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("pubsub_serverinfo_codec.hrl").
-include("logger.hrl").
-include_lib("xmpp/include/xmpp.hrl").

%% gen_mod callbacks.
-export([start/2, stop/1, depends/2, mod_options/1, get_local_features/5, mod_doc/0]).
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).
-export([in_auth_result/3, out_auth_result/2, get_info/5]).

-define(NS_URN_SERVERINFO, <<"urn:xmpp:serverinfo:0">>).
-define(PUBLIC_HOSTS_URL, <<"https://data.xmpp.net/providers/v2/providers-Ds.json">>).

-record(state, {host, pubsub_host, node, monitors = #{}, timer = undefined, public_hosts = []}).

start(Host, Opts) ->
    xmpp:register_codec(pubsub_serverinfo_codec),
    ejabberd_hooks:add(disco_local_features, Host, ?MODULE, get_local_features, 50),
    ejabberd_hooks:add(disco_info, Host, ?MODULE, get_info, 50),
    ejabberd_hooks:add(s2s_out_auth_result, Host, ?MODULE, out_auth_result, 50),
    ejabberd_hooks:add(s2s_in_auth_result, Host, ?MODULE, in_auth_result, 50),
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    ejabberd_hooks:delete(disco_local_features, Host, ?MODULE, get_local_features, 50),
    ejabberd_hooks:delete(disco_info, Host, ?MODULE, get_info, 50),
    ejabberd_hooks:delete(s2s_out_auth_result, Host, ?MODULE, out_auth_result, 50),
    ejabberd_hooks:delete(s2s_in_auth_result, Host, ?MODULE, in_auth_result, 50),
    gen_mod:stop_child(?MODULE, Host).

init([Host, _Opts]) ->
    TRef = timer:send_interval(timer:minutes(5), self(), update_pubsub),
    Monitors = init_monitors(Host),
    PublicHosts = fetch_public_hosts(),
    PubsubHost = gen_mod:get_module_opt(Host, mod_pubsub, host),
    State = #state{host = Host,
                   pubsub_host = PubsubHost,
                   node = <<"serverinfo">>,
                   timer = TRef,
                   monitors = Monitors,
                   public_hosts = PublicHosts},
    self() ! update_pubsub,
    {ok, State}.

-spec init_monitors(binary()) -> map().
init_monitors(Host) ->
    lists:foldl(
      fun(Domain, Monitors) ->
              RefIn = make_ref(), % just dummies
              RefOut = make_ref(),
              maps:merge(#{RefIn => {incoming, {Host, Domain, true}},
                           RefOut => {outgoing, {Host, Domain, true}}},
                         Monitors)
      end,
      #{},
      ejabberd_option:hosts() -- [Host]).

-spec fetch_public_hosts() -> list().
fetch_public_hosts() ->
    try
        {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(?PUBLIC_HOSTS_URL),
        case misc:json_decode(Body) of
            PublicHosts when is_list(PublicHosts) -> PublicHosts;
            Other ->
                ?WARNING_MSG("Parsed JSON for public hosts was not a list: ~p", [Other]),
                []
        end
    catch E:R ->
            ?WARNING_MSG("Failed fetching public hosts (~p): ~p", [E, R]),
            []
    end.

handle_cast({Event, Domain, Pid}, #state{host = Host, monitors = Mons} = State)
  when Event == register_in; Event == register_out ->
    Ref = monitor(process, Pid),
    IsPublic = check_if_public(Domain, State),
    NewMons = maps:put(Ref, {event_to_dir(Event), {Host, Domain, IsPublic}}, Mons),
    {noreply, State#state{monitors = NewMons}};
handle_cast(_, State) ->
    {noreply, State}.

event_to_dir(register_in) -> incoming;
event_to_dir(register_out) -> outgoing.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_info({iq_reply, IQReply, {LServer, RServer}},
	    #state{monitors = Mons} = State) ->
    case IQReply of
	#iq{type = result, sub_els = [El]} ->
	    case xmpp:decode(El) of
		#disco_info{features = Features} ->
		    case lists:member(?NS_URN_SERVERINFO, Features) of
			true ->
			    NewMons = maps:fold(fun(Ref, {Dir, {LServer0, RServer0, _}}, Acc)
                                    when LServer == LServer0, RServer == RServer0 ->
                                      maps:put(Ref, {Dir, {LServer, RServer, true}}, Acc);
                                 (Ref, Other, Acc) ->
                                      maps:put(Ref, Other, Acc)
                              end,
                              #{},
                              Mons),
			    {noreply, State#state{monitors = NewMons}};
			_ ->
			    {noreply, State}
		    end;
		_ ->
		    {noreply, State}
	    end;
	_ ->
	    {noreply, State}
    end;
handle_info(update_pubsub, State) ->
    update_pubsub(State),
    {noreply, State};
handle_info({'DOWN', Mon, process, _Pid, _Info}, #state{monitors = Mons} = State) ->
    {noreply, State#state{monitors = maps:remove(Mon, Mons)}};
handle_info(_Request, State) ->
    {noreply, State}.

terminate(_Reason, #state{monitors = Mons, timer = Timer}) ->
    case is_reference(Timer) of
	true ->
	    case erlang:cancel_timer(Timer) of
		false ->
		    receive {timeout, Timer, _} -> ok
		    after 0 -> ok
		    end;
		_ ->
		    ok
	    end;
	_ ->
	    ok
    end,
    maps:fold(
	fun(Mon, _, _) ->
	    demonitor(Mon)
	end, ok, Mons).

depends(_Host, _Opts) ->
    [{mod_pubsub, hard}].

mod_options(_Host) ->
    [].

mod_doc() -> #{}.

in_auth_result(#{server_host := Host, remote_server := RServer} = State, true, _Server) ->
    gen_server:cast(gen_mod:get_module_proc(Host, ?MODULE), {register_in, RServer, self()}),
    State;
in_auth_result(State, _, _) ->
    State.

out_auth_result(#{server_host := Host, remote_server := RServer} = State, true) ->
    gen_server:cast(gen_mod:get_module_proc(Host, ?MODULE), {register_out, RServer, self()}),
    State;
out_auth_result(State, _) ->
    State.

check_if_public(Domain, State) ->
    maybe_send_disco_info(is_public(Domain, State) orelse is_monitored(Domain, State), Domain, State).

is_public(Domain, #state{public_hosts = PublicHosts}) ->
    lists:member(Domain, PublicHosts).

is_monitored(Domain, #state{host = Host, monitors = Mons}) ->
    maps:size(
      maps:filter(
        fun(_Ref, {_Dir, {LServer, RServer, IsPublic}})
              when LServer == Host, RServer == Domain -> IsPublic;
           (_Ref, _Other) -> false
        end,
        Mons)) =/= 0.

maybe_send_disco_info(true, _Domain, _State) -> true;
maybe_send_disco_info(false, Domain, #state{host = Host}) ->
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    IQ = #iq{type = get, from = jid:make(Host),
	     to = jid:make(Domain), sub_els = [#disco_info{}]},
    ejabberd_router:route_iq(IQ, {Host, Domain}, Proc),
    false.

update_pubsub(#state{host = Host, pubsub_host = PubsubHost, node = Node, monitors = Mons}) ->
    Map = maps:fold(
            fun(_, {Dir, {MyDomain, Target, IsPublic}}, Acc) ->
                    maps:update_with(MyDomain,
                                     fun(Acc2) ->
                                             maps:update_with(Target,
                                                              fun({Types, _}) -> {Types#{Dir => true}, IsPublic} end,
                                                              {#{Dir => true}, IsPublic}, Acc2)
                                     end, #{Target => {#{Dir => true}, IsPublic}}, Acc)
            end, #{}, Mons),
    Domains = maps:fold(
                fun(MyDomain, Targets, Acc) ->
                        Remote = maps:fold(
                                   fun(Remote, {Types, true}, Acc2) ->
                                           [#pubsub_serverinfo_remote_domain{name = Remote, type = maps:keys(Types)} | Acc2];
                                      (_HiddenRemote, {Types, false}, Acc2) ->
                                           [#pubsub_serverinfo_remote_domain{type = maps:keys(Types)} | Acc2]
                                   end, [], Targets),
                        [#pubsub_serverinfo_domain{name = MyDomain, remote_domain = Remote} | Acc]
                end, [], Map),

    PubOpts = [{persist_items, true}, {max_items, 1}, {access_model, open}],
    ?DEBUG("Publishing serverinfo pubsub item on ~s: ~p", [PubsubHost, Domains]),
    mod_pubsub:publish_item(
      PubsubHost, Host, Node, jid:make(Host),
      <<"current">>, [xmpp:encode(#pubsub_serverinfo{domain = Domains})], PubOpts, all).

get_local_features({error, _} = Acc, _From, _To, _Node, _Lang) ->
    Acc;
get_local_features(Acc, _From, _To, Node, _Lang) when Node == <<>> ->
    case Acc of
	{result, Features} ->
	    {result, [?NS_URN_SERVERINFO | Features]};
	empty -> {result, [?NS_URN_SERVERINFO]}
    end;
get_local_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

get_info(Acc, Host, Mod, Node, Lang) when (Mod == undefined orelse Mod == mod_disco), Node == <<"">> ->
    case mod_disco:get_info(Acc, Host, Mod, Node, Lang) of
	[#xdata{fields = Fields} = XD | Rest] ->
	    PubsubHost = gen_mod:get_module_opt(Host, mod_pubsub, host),
	    NodeField = #xdata_field{var = <<"serverinfo-pubsub-node">>,
	                             values = [<<"xmpp:", PubsubHost/binary, "?;node=serverinfo">>]},
	    {stop, [XD#xdata{fields = Fields ++ [NodeField]} | Rest]};
	_ ->
	    Acc
    end;
get_info(Acc, Host, Mod, Node, _Lang) when Node == <<"">>, is_atom(Mod) ->
    PubsubHost = gen_mod:get_module_opt(Host, mod_pubsub, host),
    [#xdata{type = result,
	fields = [
	    #xdata_field{type = hidden,
		var = <<"FORM_TYPE">>,
		values = [?NS_SERVERINFO]},
	    #xdata_field{var = <<"serverinfo-pubsub-node">>,
                         values = [<<"xmpp:", PubsubHost/binary, "?;node=serverinfo">>]}]} | Acc];
get_info(Acc, _Host, _Mod, _Node, _Lang) ->
    Acc.
