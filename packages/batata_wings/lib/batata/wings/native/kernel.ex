defmodule Batata.Wings.Native.Kernel do
  @moduledoc false

  def main(), do: encode_layout(vertex_count(cube_state()), face_count(cube_state()))

  def cube_state() do
    vertices = [
      {0, -1_000, -1_000, -1_000},
      {1, 1_000, -1_000, -1_000},
      {2, 1_000, 1_000, -1_000},
      {3, -1_000, 1_000, -1_000},
      {4, -1_000, -1_000, 1_000},
      {5, 1_000, -1_000, 1_000},
      {6, 1_000, 1_000, 1_000},
      {7, -1_000, 1_000, 1_000}
    ]

    faces = [
      {0, [0, 3, 2, 1]},
      {1, [4, 5, 6, 7]},
      {2, [0, 1, 5, 4]},
      {3, [1, 2, 6, 5]},
      {4, [2, 3, 7, 6]},
      {5, [3, 0, 4, 7]}
    ]

    {0, vertices, faces, [], []}
  end

  def topology_stats(state) do
    vertices = elem(state, 1)
    faces = elem(state, 2)
    vertex_count = list_count(vertices)
    side_count = face_side_count(faces)
    edge_count = half_even(side_count)
    face_count = list_count(faces)

    {valid_closed_layout(vertex_count, side_count, face_count), vertex_count, edge_count,
     face_count, euler_characteristic(vertex_count, edge_count, face_count)}
  end

  def vertex_count(state), do: list_count(elem(state, 1))
  def face_count(state), do: face_list_count(elem(state, 2), 0)

  def layout_code(state) do
    encode_layout(list_count(elem(state, 1)), list_count(elem(state, 2)))
  end

  def topology_code_for_state(state) do
    vertices = elem(state, 1)
    faces = elem(state, 2)
    vertex_count = list_count(vertices)
    side_count = face_side_count(faces)
    edge_count = half_even(side_count)
    face_count = list_count(faces)

    encode_topology(
      valid_closed_layout(vertex_count, side_count, face_count),
      vertex_count,
      edge_count,
      face_count,
      euler_characteristic(vertex_count, edge_count, face_count)
    )
  end

  def select_face(state, face_id, expected_generation)
      when is_integer(face_id) and is_integer(expected_generation) do
    generation = elem(state, 0)
    faces = elem(state, 2)

    if generation != expected_generation do
      {state, 1}
    else
      if face_exists(faces, face_id) do
        {{generation, elem(state, 1), faces, [face_id], elem(state, 4)}, 0}
      else
        {state, 2}
      end
    end
  end

  def move_selected(state, dx, dy, dz, expected_generation, quota_bytes)
      when is_integer(dx) and is_integer(dy) and is_integer(dz) and
             is_integer(expected_generation) and is_integer(quota_bytes) do
    generation = elem(state, 0)
    vertices = elem(state, 1)
    faces = elem(state, 2)
    selection = elem(state, 3)
    estimated_bytes = estimate_bytes(vertices, faces)

    if generation != expected_generation do
      {state, 1}
    else
      if selection == [] do
        {state, 2}
      else
        if greater_than(estimated_bytes, quota_bytes) do
          {state, 3}
        else
          if zero_vector(dx, dy, dz) do
            {state, 0}
          else
            commit_move(state, dx, dy, dz)
          end
        end
      end
    end
  end

  def generation(state), do: elem(state, 0)
  def vertices(state), do: elem(state, 1)
  def faces(state), do: elem(state, 2)
  def selection(state), do: elem(state, 3)

  def vertex_position(state, vertex_id) when is_integer(vertex_id) do
    find_vertex(elem(state, 1), vertex_id)
  end

  def native_smoke_code(state) do
    selected_result = select_face(state, 1, 0)
    selected = elem(selected_result, 0)
    move_result = move_selected(selected, 0, 0, 250, 0, 1_024)
    moved = elem(move_result, 0)
    encode_smoke(topology_stats(moved), vertex_position(moved, 4))
  end

  def topology_code(stats) do
    encode_topology(
      elem(stats, 0),
      elem(stats, 1),
      elem(stats, 2),
      elem(stats, 3),
      elem(stats, 4)
    )
  end

  defp face_side_count([]), do: 0

  defp face_side_count([face | rest]) do
    add_integer(list_count(elem(face, 1)), face_side_count(rest))
  end

  defp valid_closed_layout(vertex_count, side_count, face_count) do
    if vertex_count == 8 do
      if side_count == 24, do: face_count == 6, else: false
    else
      false
    end
  end

  defp selected_vertex_ids([], _selection, result), do: result

  defp selected_vertex_ids([face | rest], selection, result) do
    face_id = elem(face, 0)

    if list_member(selection, face_id) do
      selected_vertex_ids(rest, selection, append_unique(elem(face, 1), result))
    else
      selected_vertex_ids(rest, selection, result)
    end
  end

  defp append_unique([], result), do: result

  defp append_unique([value | rest], result) do
    if list_member(result, value) do
      append_unique(rest, result)
    else
      append_unique(rest, [value | result])
    end
  end

  defp move_vertices([], _selected, _dx, _dy, _dz), do: []

  defp move_vertices([vertex | rest], selected, dx, dy, dz) do
    id = elem(vertex, 0)

    if list_member(selected, id) do
      [
        {id, add_integer(elem(vertex, 1), dx), add_integer(elem(vertex, 2), dy),
         add_integer(elem(vertex, 3), dz)}
        | move_vertices(rest, selected, dx, dy, dz)
      ]
    else
      [vertex | move_vertices(rest, selected, dx, dy, dz)]
    end
  end

  defp commit_move(state, dx, dy, dz) do
    generation = elem(state, 0)
    vertices = elem(state, 1)
    faces = elem(state, 2)
    selection = elem(state, 3)
    selected_vertices = selected_vertex_ids(faces, selection, [])
    moved = move_vertices(vertices, selected_vertices, dx, dy, dz)
    previous = {generation, vertices, faces, selection}
    next = {increment(generation), moved, faces, selection, [previous | elem(state, 4)]}
    {next, 0}
  end

  defp face_exists([], _face_id), do: false

  defp face_exists([face | rest], face_id) do
    if elem(face, 0) == face_id, do: true, else: face_exists(rest, face_id)
  end

  defp find_vertex([], _vertex_id), do: {}

  defp find_vertex([vertex | rest], vertex_id) do
    if elem(vertex, 0) == vertex_id, do: vertex, else: find_vertex(rest, vertex_id)
  end

  defp estimate_bytes(vertices, faces) do
    estimate_counts(list_count(vertices), list_count(faces))
  end

  defp estimate_counts(vertex_count, face_count)
       when is_integer(vertex_count) and is_integer(face_count) do
    vertex_count * 40 + face_count * 56
  end

  defp euler_characteristic(vertices, edges, faces)
       when is_integer(vertices) and is_integer(edges) and is_integer(faces) do
    vertices - edges + faces
  end

  defp encode_smoke(stats, position) do
    encode_smoke_values(
      elem(stats, 0),
      elem(stats, 1),
      elem(stats, 2),
      elem(stats, 3),
      elem(stats, 4),
      elem(position, 3)
    )
  end

  defp encode_smoke_values(true, vertices, edges, faces, euler, moved_z)
       when is_integer(vertices) and is_integer(edges) and is_integer(faces) and
              is_integer(euler) and is_integer(moved_z) do
    topology = vertices * 100_000 + edges * 1_000 + faces * 10 + euler
    topology * 2_000 + moved_z
  end

  defp encode_smoke_values(false, _vertices, _edges, _faces, _euler, _moved_z), do: -1

  defp encode_topology(true, vertices, edges, faces, euler)
       when is_integer(vertices) and is_integer(edges) and is_integer(faces) and
              is_integer(euler) do
    vertices * 100_000 + edges * 1_000 + faces * 10 + euler
  end

  defp encode_topology(false, _vertices, _edges, _faces, _euler), do: -1

  defp encode_layout(vertices, faces) when is_integer(vertices) and is_integer(faces) do
    vertices * 100 + faces
  end

  defp add_integer(left, right) when is_integer(left) and is_integer(right), do: left + right
  defp increment(value) when is_integer(value), do: value + 1
  defp half_even(value), do: half_even(value, 0)
  defp half_even(0, result), do: result

  defp half_even(value, result) when is_integer(value) and is_integer(result) and value > 0 do
    half_even(value - 2, result + 1)
  end

  defp zero_vector(0, 0, 0), do: true
  defp zero_vector(_dx, _dy, _dz), do: false

  defp greater_than(left, right) when left > right, do: true
  defp greater_than(_left, _right), do: false

  defp list_count(values), do: list_count(values, 0)
  defp list_count([], count), do: count

  defp list_count([_value | rest], count) when is_integer(count),
    do: list_count(rest, count + 1)

  defp face_list_count([], count), do: count

  defp face_list_count([_value | rest], count) when is_integer(count),
    do: face_list_count(rest, count + 1)

  defp list_member([], _value), do: false

  defp list_member([head | rest], value) do
    if head == value, do: true, else: list_member(rest, value)
  end
end
