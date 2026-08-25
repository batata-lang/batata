%% Test-only adapter over the pinned upstream Wings3D implementation.
-module(batata_wings_oracle).
-export([cube_smooth/0]).

-include("wings.hrl").

cube_smooth() ->
    Faces = [
        [0,3,2,1],
        [4,5,6,7],
        [0,1,5,4],
        [1,2,6,5],
        [2,3,7,6],
        [3,0,4,7]
    ],
    Vertices = [
        {-1.0,-1.0,-1.0},
        {1.0,-1.0,-1.0},
        {1.0,1.0,-1.0},
        {-1.0,1.0,-1.0},
        {-1.0,-1.0,1.0},
        {1.0,-1.0,1.0},
        {1.0,1.0,1.0},
        {-1.0,1.0,1.0}
    ],
    Mesh0 = wings_we_build:we(Faces, Vertices, []),
    Mesh = wings_subdiv:smooth(Mesh0),
    Positions = array:sparse_to_orddict(Mesh#we.vp),
    #{
        <<"vertices">> => length(Positions),
        <<"edges">> => array:sparse_foldl(fun(_, _, Count) -> Count + 1 end, 0, Mesh#we.es),
        <<"faces">> => gb_trees:size(Mesh#we.fs),
        <<"positions">> => Positions
    }.
