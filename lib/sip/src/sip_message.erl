%%%----------------------------------------------------------------
%%% @author  Ivan Dubrov <wfragg@gmail.com>
%%% @doc
%%% SIP messages parsing/generation.
%%% @end
%%% @copyright 2011 Ivan Dubrov
%%%----------------------------------------------------------------
-module(sip_message).

%%-----------------------------------------------------------------
%% Exports
%%-----------------------------------------------------------------
-export([is_request/1, is_response/1, to_binary/1]).
-export([is_provisional_response/1, is_redirect_response/1, method/1]).
-export([parse_stream/2, parse_datagram/1, parse_all_headers/1, sort_headers/1]).
-export([create_ack/2, create_response/3]).
-export([validate_request/1]).
-export([update_top_header/3, replace_top_header/3]).
-export([top_header/2, top_via_branch/1, foldl_headers/4]).

%%-----------------------------------------------------------------
%% Macros
%%-----------------------------------------------------------------
-define(SIPVERSION, "SIP/2.0").

%%-----------------------------------------------------------------
%% Include files
%%-----------------------------------------------------------------
-include_lib("sip_common.hrl").
-include_lib("sip.hrl").

%% Types

%% Internal state
%% 'BEFORE' -- state before Start-Line
%% 'HEADERS' -- state after first Start-Line character was received
%% {'BODY', Message, Length} -- state after receiving headers, but before body (\r\n\r\n)
-type state() :: {'BEFORE' | 'HEADERS' | {'BODY', #sip_message{}, integer()}, binary()}.

%%-----------------------------------------------------------------
%% API functions
%%-----------------------------------------------------------------

%% @doc Check if message is SIP request.
%% @end
-spec is_request(#sip_message{}) -> boolean().
is_request(#sip_message{kind = #sip_request{}}) -> true;
is_request(#sip_message{kind = #sip_response{}}) -> false.

%% @doc Check if message is SIP response.
%% @end
-spec is_response(#sip_message{}) -> boolean().
is_response(Message) ->
    not is_request(Message).

%% @doc Check if message is SIP provisional response (1xx).
%% @end
-spec is_provisional_response(#sip_message{}) -> boolean().
is_provisional_response(#sip_message{kind = #sip_response{status = Status}}) ->
    Status >= 100 andalso Status =< 199.

%% @doc Check if message is SIP redirect response (3xx).
%% @end
-spec is_redirect_response(#sip_message{}) -> boolean().
is_redirect_response(#sip_message{kind = #sip_response{status = Status}}) ->
    Status >= 300 andalso Status =< 399.

%% @doc Retrieve method of SIP message
%%
%% Returns `Method' from `start-line' for requests, `Method' from `CSeq' header
%% for responses.
%% @end
-spec method(#sip_message{}) -> atom() | binary().
method(#sip_message{kind = #sip_request{method = Method}}) -> Method;
method(#sip_message{kind = #sip_response{}} = Msg) ->
    {ok, CSeq} = sip_message:top_header('cseq', Msg),
    CSeq#sip_hdr_cseq.method.

-spec to_binary(#sip_message{}) -> binary().
to_binary(Message) ->
    Top = case Message#sip_message.kind of
              #sip_request{method = Method, uri = URI} ->
                  URIBin = sip_uri:format(URI),
                  <<(sip_binary:any_to_binary(Method))/binary, " ", URIBin/binary, " ", ?SIPVERSION>>;
              #sip_response{status = Status, reason = Reason} ->
                  StatusStr = list_to_binary(integer_to_list(Status)),
                  <<?SIPVERSION, " ", StatusStr/binary, " ", Reason/binary>>
          end,
    Headers = sip_headers:format_headers(Message#sip_message.headers),
    iolist_to_binary([Top, <<"\r\n">>, Headers, <<"\r\n">>, Message#sip_message.body]).


%% @doc Update value of top header with given name.
%%
%% If header value is multi-value, only first element of the list (top header)
%% is updated by the function.
%%
%% <em>Note: this function parses the header value if header is in binary form.</em>
%% <em>If no header is found with given name, update function is called with
%% `undefined' parameter. If function returns any value other than `undefined',
%% a new header with that value is added.</em>
%% @end
-spec update_top_header(
        atom() | binary(),
        fun((Value :: any()) -> UpdatedValue :: any()),
        #sip_message{}) -> #sip_message{}.
update_top_header(HeaderName, Fun, Request) ->
    Headers = update_header(HeaderName, Fun, Request#sip_message.headers),
    Request#sip_message{headers = Headers}.

%% Internal function to update the header list
update_header(HeaderName, Fun, [{HeaderName, Value} | Rest]) ->
    % Parse header if it is not parsed yet
    UpdatedValue =
        case sip_headers:parse(HeaderName, Value) of
            % multi-value header
            [Top | Rest2] -> [Fun(Top) | Rest2];
            % single value header
            Top -> Fun(Top)
        end,
    [{HeaderName, UpdatedValue} | Rest];
update_header(HeaderName, Fun, [Header | Rest]) ->
    [Header | update_header(HeaderName, Fun, Rest)];
update_header(HeaderName, Fun, []) ->
    % generate a new header value
    case Fun(undefined) of
        undefined -> [];
        Value -> [{HeaderName, Value}]
    end.

%% @doc
%% Replace value of top header with given name with provided value. If
%% header value is multi-value (a list), the first element of the list
%% is replaced.
%%
%% <em>Note that header is not added automatically, if there is no header with given name</em>
%% @end
-spec replace_top_header(atom() | binary(), term() | binary(), #sip_message{}) -> #sip_message{}.
replace_top_header(HeaderName, Value, Message) ->
    UpdateFun = fun
                   (undefined) -> undefined; % do not add a new one
                   ([_ | Rest]) -> [Value | Rest];
                   (_) -> Value
                end,
    update_top_header(HeaderName, UpdateFun, Message).

%% @doc
%% Retrieve `branch' parameter of top via header or `undefined' if no such
%% parameter present.
%%
%% This function parses the Via: header value if header is in binary form.
%% @end
-spec top_via_branch(#sip_message{}) -> {ok, binary()} | {error, not_found}.
top_via_branch(Message) when is_record(Message, sip_message) ->
    {ok, Via} = top_header('via', Message#sip_message.headers),
    case lists:keyfind(branch, 1, Via#sip_hdr_via.params) of
        {branch, Branch} -> {ok, Branch};
        false -> {error, not_found}
    end.

%% @doc Calls `Fun(Value, AccIn)' on all successive header values named `Name'
%%
%% <em>Note: this function parses the header value if header is in binary form.</em>
%% @end
-spec foldl_headers(atom() | binary(), 
                    fun ((Value::term(), AccIn::term()) -> AccOut :: term()), 
                    term(),
                    #sip_message{}) -> Acc :: term(). 
foldl_headers(Name, Fun, Acc0, Msg) when is_function(Fun, 2), is_record(Msg, sip_message) ->
    Headers = lists:filter(fun ({N, _Value}) -> N =:= Name end, Msg#sip_message.headers),
    Parsed = lists:map(fun ({_Name, Value}) -> sip_headers:parse(Name, Value) end, Headers),
    Flat = lists:flatten(Parsed),
    lists:foldl(Fun, Acc0, Flat).

%% @doc
%% Retrieve top value of given header. Accepts either full SIP message
%% or list of headers.
%%
%% This function parses the header value if header is in binary form.
%% @end
-spec top_header(atom() | binary(), #sip_message{} | [{Name :: atom() | binary(), Value :: binary() | term()}]) ->
          {ok, term()} | {error, not_found}.
top_header(Name, Message) when is_record(Message, sip_message) ->
    top_header(Name, Message#sip_message.headers);
top_header(Name, Headers) when is_list(Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        false -> {error, not_found};
        {Name, Value} ->
            case sip_headers:parse(Name, Value) of
                [Top | _] -> {ok, Top}; % support for multiple header values
                Top -> {ok, Top}
            end
    end.


%% @doc
%% Parses the datagram for SIP packet. The headers of the returned message are
%% retained in binary form for performance reasons. Use {@link parse_whole/1}
%% to parse the whole message or {@link sip_headers:parse/2} to parse
%% single header.
%% @end
-spec parse_datagram(Datagram :: binary()) ->
          {ok, #sip_message{}}
        | {error, content_too_small, #sip_message{}}.
parse_datagram(Datagram) ->
    {Pos, _Length} = binary:match(Datagram, <<"\r\n\r\n">>),
    Pos2 = Pos + 2,
    <<Top:Pos2/binary, "\r\n", Body/binary>> = Datagram,
    [Start, HeadersBin] = binary:split(Top, <<"\r\n">>),
    Headers = sip_headers:parse_headers(HeadersBin),
    Kind = parse_start_line(Start),

    % RFC 3261 18.3
    case top_header('content-length', Headers) of
        % Content-Length is present
        {ok, ContentLength} when ContentLength =< size(Body) ->
            <<Body2:ContentLength/binary, _/binary>> = Body,
            {ok, #sip_message{kind = Kind, headers = Headers, body = Body2}};
        {ok, _} ->
            {error, content_too_small, #sip_message{kind = Kind, headers = Headers, body = <<>>}};
        % Content-Length is not present
        {error, not_found} ->
            {ok, #sip_message{kind = Kind, headers = Headers, body = Body}}
    end.

%% @doc Parses the stream for complete SIP messages.

%% Return new parser state and possibly a message extracted from the
%% stream. The headers of the returned messages are retained in binary
%% form for performance reasons. Use {@link parse_whole/1} to parse the
%% whole message or {@link sip_headers:parse/2} to parse single header.
%%
%% <em>Note: caller is required to call this method with empty packet (<<>>)
%% until no new messages are returned</em>
%% @end
-spec parse_stream(Packet :: binary(), State :: state() | 'none') ->
          {ok, state()} |
          {ok, #sip_message{}, state()} |
          {error, no_content_length, #sip_message{}, state()}.
parse_stream(Packet, none) -> parse_stream(Packet, {'BEFORE', <<>>});
parse_stream(Packet, {State, Frame}) when is_binary(Packet) ->
    NewFrame = <<Frame/binary, Packet/binary>>,
    parse_stream_internal({State, NewFrame}, size(Frame)).

%% @doc
%% Parses all headers of the message.
%% @end
-spec parse_all_headers(#sip_message{}) -> #sip_message{}.
parse_all_headers(Msg) when is_record(Msg, sip_message) ->
    Headers = [{Name, sip_headers:parse(Name, Value)} || {Name, Value} <- Msg#sip_message.headers],
    Msg#sip_message{headers = Headers}.

%% @doc
%% Parse and stable sort all headers of the message. This function is mostly used for testing
%% purposes before comparing the messages.
%% @end
-spec sort_headers(#sip_message{}) -> #sip_message{}.
sort_headers(Msg) when is_record(Msg, sip_message) ->
    Msg2 = parse_all_headers(Msg),
    Msg2#sip_message{headers = lists:keysort(1, Msg2#sip_message.headers)}.

%%-----------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------

parse_stream_internal({'BEFORE', <<"\r\n", Rest/binary>>}, _From) ->
    % RFC 3261 7.5  Implementations processing SIP messages over
    % stream-oriented transports MUST ignore any CRLF appearing before the
    % start-line
    parse_stream_internal({'BEFORE', Rest}, 0);
parse_stream_internal({'BEFORE', Frame}, _From) when Frame =:= <<"\r">>; Frame =:= <<>> ->
    % frame is empty or "\r" while ignoring \r\n, return same state
    {ok, {'BEFORE', Frame}};
parse_stream_internal({State, Frame}, From) when State =:= 'HEADERS'; State =:= 'BEFORE'->
    % Search if header-body delimiter is present
    % We need to look back 3 characters at most
    % (last frame ends with \r\n\r, we have received \n)
    case has_header_delimiter(Frame, From - 3) of
        false -> {ok, {'HEADERS', Frame}};
        Pos ->
            % Split packet into headers and the rest
            Pos2 = Pos + 2,
            <<Top:Pos2/binary, "\r\n", Rest/binary>> = Frame,
            % Get start line and headers
            [Start, HeadersBin] = binary:split(Top, <<"\r\n">>),
            Headers = sip_headers:parse_headers(HeadersBin),
            Kind = parse_start_line(Start),

            % Check content length present
            case top_header('content-length', Headers) of
                {ok, ContentLength} ->
                    % continue processing the message body
                    Msg = #sip_message{kind = Kind, headers = Headers},
                    NewState = {'BODY', Msg, ContentLength},
                    parse_stream_internal({NewState, Rest}, 0);
                {error, not_found} ->
                    % return bad message
                    Msg = #sip_message{kind = Kind, headers = Headers, body = Rest},
                    {error, no_content_length, Msg, {'BEFORE', <<>>}}
            end
    end;
parse_stream_internal({{'BODY', Msg, ContentLength}, Frame}, _)
  when size(Frame) >= ContentLength ->
    % received the whole body
    <<Body:ContentLength/binary, Rest/binary>> = Frame,
    % return parsed message
    {ok, Msg#sip_message{body = Body}, {'BEFORE', Rest}};
parse_stream_internal(State, _) ->
    % nothing to parse yet, return current state
    {ok, State}.

%% Check if we have header-body delimiter in the received packet
has_header_delimiter(Data, Offset) when Offset < 0 ->
    has_header_delimiter(Data, 0);

has_header_delimiter(Data, Offset) ->
    case binary:match(Data, <<"\r\n\r\n">>, [{scope, {Offset, size(Data) - Offset}}]) of
        nomatch -> false;
        {Pos, _} -> Pos
    end.

%% Request-Line   =  Method SP Request-URI SP SIP-Version CRLF
%% Status-Line  =  SIP-Version SP Status-Code SP Reason-Phrase CRLF
%% start-line   =  Request-Line / Status-Line
%%
%% RFC3261 7.1: The SIP-Version string is case-insensitive, but implementations MUST send upper-case.
-spec parse_start_line(binary()) -> #sip_request{} | #sip_response{}.
parse_start_line(StartLine) when is_binary(StartLine) ->
    % split on three parts
    [First, Rest] = binary:split(StartLine, <<" ">>),
    [Second, Third] = binary:split(Rest, <<" ">>),
    case {First, Second, Third} of
        {Method, RequestURI, <<?SIPVERSION>>} ->
            #sip_request{method = sip_binary:binary_to_existing_atom(sip_binary:to_upper(Method)),
                         uri = RequestURI};

        {<<?SIPVERSION>>, <<A,B,C>>, ReasonPhrase} when
          $1 =< A andalso A =< $6 andalso % 1xx - 6xx
          $0 =< B andalso B =< $9 andalso
          $0 =< C andalso C =< $9 ->
            #sip_response{status = list_to_integer([A, B, C]),
                          reason = ReasonPhrase}
    end.

%% @doc
%% RFC 3261, 17.1.1.3 Construction of the ACK Request
%% @end
-spec create_ack(#sip_message{}, #sip_message{}) -> #sip_message{}.
create_ack(Request, Response) when is_record(Request, sip_message),
                                   is_record(Response, sip_message) ->
    #sip_request{method = Method, uri = RequestURI} = Request#sip_message.kind,

    % Call-Id, From, CSeq (with method changed to 'ACK') and Route (for 'INVITE'
    % response ACKs) are taken from the original request
    FoldFun = fun ({'call-id', _} = H, List) -> [H|List];
                  ({'from', _} = H, List) -> [H|List];
                  ({'cseq', Value}, List) ->
                       CSeq = sip_headers:parse('cseq', Value),
                       CSeq2 = CSeq#sip_hdr_cseq{method = 'ACK'},
                       [{'cseq', CSeq2} | List];
                  ({'route', _} = H, List) when Method =:= 'INVITE' -> [H|List];
                  (_, List) -> List
           end,
    ReqHeaders = lists:reverse(lists:foldl(FoldFun, [], Request#sip_message.headers)),

    % Via is taken from top Via of the original request
    {ok, Via} = top_header('via', Request),

    % To goes from the response
    {ok, To} = top_header('to', Response),

    #sip_message{kind = #sip_request{method = 'ACK', uri = RequestURI},
                 body = <<>>,
                 headers = [{'via', Via}, {'to', To} | ReqHeaders]}.


%% @doc Create response for given request
%% @end
-spec create_response(#sip_message{}, integer(), binary()) -> #sip_message{}.
create_response(Request, Status, Reason) ->
    Headers = [{Name, Value} || {Name, Value} <- Request#sip_message.headers,
                                (Name =:= 'from' orelse Name =:= 'call-id' orelse
                                 Name =:= 'cseq' orelse Name =:= 'via' orelse
                                 Name =:= 'to')],
    Kind = #sip_response{status = Status, reason = Reason},
    #sip_message{kind = Kind, headers = Headers}.

%% @doc Validate that request contains all required headers
%% A valid SIP request formulated by a UAC MUST, at a minimum, contain
%% the following header fields: To, From, CSeq, Call-ID, Max-Forwards,
%% and Via; all of these header fields are mandatory in all SIP
%% requests.
%% @end
-spec validate_request(#sip_message{}) -> ok | {error, Reason :: term()}.
validate_request(Request) when is_record(Request, sip_message) ->
    Method = Request#sip_message.kind#sip_request.method,
    CountFun =
        fun ({Name, Value}, Counts) ->
                 % assign tuple index for every header being counted
                 Idx = case Name of
                           'to' -> 1;
                           'from' -> 2;
                           'cseq' -> 3;
                           'call-id' -> 4;
                           'max-forwards' -> 5;
                           'via' -> 6;
                           'contact' -> 7;
                           _ -> 0
                       end,
                 if
                     Idx > 0 ->
                         Incr = if is_list(Value) -> length(Value); true -> 1 end,
                         setelement(Idx, Counts, element(Idx, Counts) + Incr);
                     true -> Counts
                 end
        end,

    % Count headers
    case lists:foldl(CountFun, {0, 0, 0, 0, 0, 0, 0}, Request#sip_message.headers) of
        C when C >= {1, 1, 1, 1, 1, 1, 0}, % Each header must be at least once (except contact),
               C =< {1, 1, 1, 1, 1, a, 0}, % except Via:, which must be at least once (atom > every possible number)

               % The Contact header field MUST be present and contain exactly one SIP
               % or SIPS URI in any request that can result in the establishment of a
               % dialog.
               (Method =/= 'INVITE' orelse element(7, C) =:= 1)
          -> ok;
        _ -> {error, invalid_headers}
    end.

%%-----------------------------------------------------------------
%% Tests
%%-----------------------------------------------------------------
-ifndef(NO_TEST).

-spec parse_request_line_test_() -> term().
parse_request_line_test_() ->
    [?_assertEqual(#sip_request{method = 'INVITE', uri = <<"sip:bob@biloxi.com">>},
                   parse_start_line(<<"INVITE sip:bob@biloxi.com SIP/2.0">>)),
     ?_assertException(error, {case_clause, _}, parse_start_line(<<"INV ITE sip:bob@biloxi.com SIP/2.0">>)),
     ?_assertEqual(#sip_response{status = 200, reason = <<"OK">>},
                   parse_start_line(<<"SIP/2.0 200 OK">>)),
     ?_assertException(error, {case_clause, _}, parse_start_line(<<"SIP/2.0 099 Invalid">>))
    ].

-spec parse_stream_test_() -> term().
parse_stream_test_() ->
    SampleRequest = #sip_request{method = 'INVITE', uri = <<"sip:urn:service:test">>},
    SampleMessage = #sip_message{kind = SampleRequest,
                                 headers = [{'content-length', <<"5">>}],
                                 body = <<"Hello">>},
    [ %% Skipping \r\n
     ?_assertEqual({ok, {'BEFORE', <<>>}},
                   parse_stream(<<>>, none)),
     ?_assertEqual({ok, {'BEFORE', <<>>}},
                   parse_stream(<<"\r\n">>, none)),
     ?_assertEqual({ok, {'BEFORE', <<"\r">>}},
                   parse_stream(<<"\r">>, none)),

     % Test headers-body delimiter test
     ?_assertEqual({ok, {'HEADERS', <<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r">>}},
                   parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r">>, none)),

     ?_assertEqual({ok, {{'BODY', SampleMessage#sip_message{body = <<>>}, 5}, <<>>}},
                   parse_stream(<<"\n">>,
                                {'HEADERS', <<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r">>})),

     ?_assertEqual({ok, {{'BODY', SampleMessage#sip_message{body = <<>>}, 5}, <<"He">>}},
                   parse_stream(<<"He">>,
                                {{'BODY', SampleMessage#sip_message{body = <<>>}, 5}, <<>>})),

     % Parse the whole body
     ?_assertEqual({ok, SampleMessage, {'BEFORE', <<>>}},
                   parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r\nHello">>, none)),
     ?_assertEqual({ok, SampleMessage, {'BEFORE', <<>>}},
                   parse_stream(<<"Hello">>,
                                {{'BODY', SampleMessage#sip_message{body = <<>>}, 5}, <<>>})),
     ?_assertEqual({ok,
                    SampleMessage#sip_message{headers = [{<<"x-custom">>, <<"Nothing">>}, {'content-length', <<"5">>}]},
                    {'BEFORE', <<>>}},
                   parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nX-Custom: Nothing\r\nContent-Length: 5\r\n\r\nHello">>,
                                {'BEFORE', <<>>})),

     % Multiple messages in stream
     ?_assertEqual({ok, SampleMessage, {'BEFORE', <<"\r\nINVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r\nHello">>}},
                   parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r\nHello\r\nINVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r\nHello">>, none)),

     % No Content-Length
     ?_assertEqual({error,
                    no_content_length,
                    #sip_message{kind = SampleRequest,
                                 headers = [{<<"x-custom">>, <<"Nothing">>}],
                                 body = <<"Hello">>},
                    {'BEFORE', <<>>}},
                   parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nX-Custom: Nothing\r\n\r\nHello">>,
                                {'BEFORE', <<>>})),
     ?_assertEqual({error,
                    no_content_length,
                    #sip_message{kind = #sip_response{status = 200, reason = <<"Ok">>}},
                    {'BEFORE', <<>>}},
                   parse_stream(<<"SIP/2.0 200 Ok\r\n\r\n">>,
                                {'BEFORE', <<>>}))
    ].

-spec parse_datagram_test_() -> term().
parse_datagram_test_() ->
    SampleRequest = #sip_request{method = 'INVITE', uri = <<"sip:urn:service:test">>},
    SampleMessage = #sip_message{kind = SampleRequest,
                                 headers = [{'content-length', <<"5">>}],
                                 body = <<"Hello">>},
    SampleResponse = #sip_response{reason = <<"Moved Permanently">>, status = 301},
    SampleResponseMessage = #sip_message{kind = SampleResponse,
                                         headers = [{'content-length', <<"5">>}],
                                         body = <<"Hello">>},
    [
     % Parse the whole body
     ?_assertEqual({ok, SampleMessage},
                   parse_datagram(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r\nHello">>)),
     ?_assertEqual({ok, SampleMessage#sip_message{headers = [{<<"x-custom">>, <<"Nothing">>}, {'content-length', <<"5">>}]}},
                   parse_datagram(<<"INVITE sip:urn:service:test SIP/2.0\r\nX-Custom: Nothing\r\nContent-Length: 5\r\n\r\nHello!!!">>)),
     ?_assertEqual({ok, SampleResponseMessage},
                   parse_datagram(<<"SIP/2.0 301 Moved Permanently\r\nContent-Length: 5\r\n\r\nHello">>)),

     % Message too small
     ?_assertEqual({error, content_too_small,
                           #sip_message{kind = SampleRequest,
                                        headers = [{'content-length', <<"10">>}]}},
                   parse_datagram(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 10\r\n\r\nHello">>)),
     ?_assertEqual({error, content_too_small,
                           #sip_message{kind = #sip_response{status = 200, reason = <<"Ok">>},
                                        headers = [{'content-length', <<"10">>}]}},
                   parse_datagram(<<"SIP/2.0 200 Ok\r\nContent-Length: 10\r\n\r\n">>)),

     % No Content-Length
     ?_assertEqual({ok, #sip_message{kind = SampleRequest,
                                     headers = [{<<"x-custom">>, <<"Nothing">>}],
                                     body = <<"Hello">> } },
                   parse_datagram(<<"INVITE sip:urn:service:test SIP/2.0\r\nX-Custom: Nothing\r\n\r\nHello">>)),
     ?_assertEqual({ok, #sip_message{kind = #sip_response{status = 200, reason = <<"Ok">>} } },
                   parse_datagram(<<"SIP/2.0 200 Ok\r\n\r\n">>))
    ].

-spec is_test_() -> term().
is_test_() ->
    {ok, Request, _} = parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\nX-Custom: Nothing\r\n\r\nHello">>, none),
    {ok, Response, _} = parse_stream(<<"SIP/2.0 200 Ok\r\nContent-Length: 5\r\n\r\nHello">>, none),
    {ok, RedResponse, _} = parse_stream(<<"SIP/2.0 301 Moved Permanently\r\nContent-Length: 5\r\n\r\nHello">>, none),
    {ok, ProvResponse} = parse_datagram(<<"SIP/2.0 100 Trying\r\n\r\n">>),
    [?_assertEqual(true, is_request(Request)),
     ?_assertEqual(false, is_request(Response)),
     ?_assertEqual(false, is_response(Request)),
     ?_assertEqual(true, is_response(Response)),
     ?_assertEqual(true, is_provisional_response(ProvResponse)),
     ?_assertEqual(false, is_provisional_response(Response)),
     ?_assertEqual(true, is_redirect_response(RedResponse)),
     ?_assertEqual(false, is_redirect_response(Response)),
     ?_assertEqual(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\nx-custom: Nothing\r\n\r\nHello">>, to_binary(Request)),
     ?_assertEqual(<<"SIP/2.0 200 Ok\r\nContent-Length: 5\r\n\r\nHello">>, to_binary(Response))
    ].


-spec create_ack_test_() -> list().
create_ack_test_() ->
    ReqHeaders = [
                  {'via', <<"SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bKkjshdyff">>},
                  {'to', <<"Bob <sip:bob@biloxi.com>">>},
                  {'from', <<"Alice <sip:alice@atlanta.com>;tag=88sja8x">>},
                  {'call-id', <<"987asjd97y7atg">>},
                  {'cseq', <<"986759 INVITE">>},
                  {'route', <<"<sip:alice@atlanta.com>">>},
                  {'route', <<"<sip:bob@biloxi.com>">>}
                  ],
    OrigRequest = #sip_message{kind = #sip_request{method = 'INVITE', uri = <<"sip:bob@biloxi.com">>}, headers = ReqHeaders},

    RespHeaders = lists:keyreplace('to', 1, ReqHeaders, {'to', <<"Bob <sip:bob@biloxi.com>;tag=1928301774">>}),
    Response = #sip_message{kind = #sip_response{status = 500, reason = <<"Internal error">>}, headers = RespHeaders},

    ACKHeaders = lists:keyreplace('cseq', 1, RespHeaders, {'cseq', <<"986759 ACK">>}),
    ACK = #sip_message{kind = #sip_request{method = 'ACK', uri = <<"sip:bob@biloxi.com">>}, headers = ACKHeaders},
    [
     ?_assertEqual(sort_headers(ACK), sort_headers(create_ack(OrigRequest, Response)))
     ].

-spec header_test_() -> list().
header_test_() ->

    CSeq = sip_headers:cseq(110, 'INVITE'),
    Via1 = sip_headers:via(udp, {"127.0.0.1", 5060}, [{branch, <<"z9hG4bK776asdhds">>}]),
    Via2 = sip_headers:via(tcp, {"127.0.0.2", 15060}, [{ttl, 4}]),
    Via1Up = sip_headers:via(udp, {"localhost", 5060}, []),
    UpdateFun = fun (Value) when Value =:= Via1 -> Via1Up end,
    InsertFun = fun (undefined) -> Via1Up end,

    ViaMsg =  #sip_message{headers = [{'content-length', 123},
                                      {'via', [Via1]},
                                      {'via', [Via2]}]},
    ViaMsgUp = #sip_message{headers = [{'content-length', 123},
                                       {'via', [Via1Up]},
                                       {'via', [Via2]}]},
    ViaMsg2 = #sip_message{headers = [{'content-length', 123}, {'via', [Via1, Via2]}]},
    ViaMsg2Up = #sip_message{headers = [{'content-length', 123}, {'via', [Via1Up, Via2]}]},
    NoViaMsg = #sip_message{headers = [{'content-length', 123}, {'cseq', CSeq}]},
    NewViaMsg = #sip_message{headers = [{'content-length', 123}, {'cseq', CSeq}, {'via', Via1Up}]},

    URI = <<"sip@nowhere.invalid">>,
    ValidRequest =
        #sip_message{kind = #sip_request{method = 'OPTIONS', uri = URI},
                     headers = [{to, sip_headers:address(<<>>, URI, [])},
                                {from, sip_headers:address(<<>>, URI, [])},
                                {cseq, sip_headers:cseq(1, 'OPTIONS')},
                                {'call-id', <<"123">>},
                                {'max-forwards', 70},
                                {via, sip_headers:via(udp, "localhost", [])}]},

    % No contact in INVITE
    InvalidRequest =
        ValidRequest#sip_message{kind = #sip_request{method = 'INVITE', uri = URI}},
    [% Header lookup functions
     ?_assertEqual({ok, Via1}, top_header('via', [{'via', [Via1, Via2]}])),
     ?_assertEqual({ok, <<"z9hG4bK776asdhds">>}, top_via_branch(#sip_message{headers = [{'via', [Via1]}, {'via', [Via2]}]})),
     ?_assertEqual({error, not_found}, top_via_branch(#sip_message{headers = [{'via', [Via2]}]})),

     % Header update functions
     ?_assertEqual(ViaMsgUp, update_top_header('via', UpdateFun, ViaMsg)),
     ?_assertEqual(NewViaMsg, update_top_header('via', InsertFun, NoViaMsg)),

     ?_assertEqual(NoViaMsg, replace_top_header('via', Via1Up, NoViaMsg)),
     ?_assertEqual(ViaMsgUp, replace_top_header('via', Via1Up, ViaMsg)),
     ?_assertEqual(ViaMsg2Up, replace_top_header('via', Via1Up, ViaMsg2)),

     % Validation
     ?_assertEqual(ok, validate_request(ValidRequest)),
     ?_assertEqual({error, invalid_headers}, validate_request(InvalidRequest))
     ].
-endif.
