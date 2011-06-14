%%%----------------------------------------------------------------
%%% @author  Ivan Dubrov <wfragg@gmail.com>
%%% @doc
%%% @end
%%% @copyright 2011 Ivan Dubrov
%%%----------------------------------------------------------------

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

%% @doc
%% According to the RFC 3261 18, connections are indexed by the tuple
%% formed from the address, port, and transport protocol at the far end
%% of the connection
%% ttl is TTL for multicasts (only used when address is multicast address)
%% @end
-record(sip_endpoint, {address, port, transport, ttl = 1}).
