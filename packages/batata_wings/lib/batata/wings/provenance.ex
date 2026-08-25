defmodule Batata.Wings.Provenance do
  @moduledoc "Pinned upstream identity and source mapping for the Wings3D port."

  @upstream "https://github.com/dgud/wings"
  @commit "e12ef3ce267c4d9ecb33d4845bdc9275f1a4b433"

  @source_mapping %{
    "e3d/e3d_vec.erl" => "Batata.Wings.Vec3",
    "src/wings_extrude_edge.erl" => "Batata.Wings.Operation.Bevel",
    "src/wings_extrude_face.erl" => "Batata.Wings.Operation.Extrude",
    "src/wings_face.erl" => "Batata.Wings.Face",
    "src/wings_face_cmd.erl" => "Batata.Wings.Operation.Extrude/Inset",
    "src/wings_move.erl" => "Batata.Wings.Operation.Move",
    "src/wings_pick.erl" => "Batata.Wings.Picking (behavior reference only)",
    "src/wings_sel.erl" => "Batata.Wings.Selection",
    "src/wings_subdiv.erl" => "Batata.Wings.Subdivision",
    "src/wings_undo.erl" => "Batata.Wings.History",
    "src/wings_vertex.erl" => "Batata.Wings.Vertex",
    "src/wings_we.erl" => "Batata.Wings.Topology",
    "src/wings_we_build.erl" => "Batata.Wings.Topology.Build"
  }

  @spec provenance() :: map()
  def provenance do
    %{
      "license" => "LICENSE.wings",
      "source_mapping" => @source_mapping,
      "upstream" => @upstream,
      "upstream_commit" => @commit
    }
  end
end
