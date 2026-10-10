-module(albedo_context_snapshot).
-export([page_count/2, page/3, byte_page_count/2, byte_page/3]).

page_count(Content, Size) when Size > 0 ->
    (scalar_count(Content, 0) + Size - 1) div Size.

scalar_count(<<>>, Count) -> Count;
scalar_count(<<_/utf8, Rest/binary>>, Count) -> scalar_count(Rest, Count + 1).

page(Content, Index, Size) when Index >= 0, Size > 0 ->
    Start = skip(Content, Index * Size),
    End = skip(Start, Size),
    %% Do not keep the whole rendered history alive through a small page.
    binary:copy(binary:part(Start, 0, byte_size(Start) - byte_size(End))).

skip(Content, 0) -> Content;
skip(<<>>, _) -> <<>>;
skip(<<_/utf8, Rest/binary>>, Count) -> skip(Rest, Count - 1).


%% Dynamic domain sections have a byte cap, with the exact same boundaries in
%% count/read operations. Valid UTF-8 needs at most three boundary adjustments.
%% Size >= 4 guarantees every page advances even for a four-byte codepoint.
byte_page_count(Content, Size) when Size >= 4 -> byte_pages(Content, Size, 0).
byte_pages(<<>>, _, Count) -> Count;
byte_pages(Content, Size, Count) ->
    Cut = byte_cut(Content, Size),
    <<_:Cut/binary, Rest/binary>> = Content,
    byte_pages(Rest, Size, Count + 1).

byte_page(Content, Index, Size) when Index >= 0, Size >= 4 ->
    Start = skip_byte_pages(Content, Index, Size),
    Cut = byte_cut(Start, Size),
    binary:copy(binary:part(Start, 0, Cut)).

skip_byte_pages(Content, 0, _) -> Content;
skip_byte_pages(<<>>, _, _) -> <<>>;
skip_byte_pages(Content, Count, Size) ->
    Cut = byte_cut(Content, Size),
    <<_:Cut/binary, Rest/binary>> = Content,
    skip_byte_pages(Rest, Count - 1, Size).

byte_cut(Content, Size) when byte_size(Content) =< Size -> byte_size(Content);
byte_cut(Content, Size) -> codepoint_boundary(Content, Size).

codepoint_boundary(Content, Position) ->
    case binary:at(Content, Position) band 16#c0 of
        16#80 -> codepoint_boundary(Content, Position - 1);
        _ -> Position
    end.
