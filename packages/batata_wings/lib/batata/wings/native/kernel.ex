defmodule Batata.Wings.Native.Kernel do
  @moduledoc false

  def main(), do: {native_editor_smoke_code()}

  def native_editor_smoke_code() do
    picked = editor_pointer_button(nil, 3, 0, 0, 5_000, 0, 0, -10)
    state_code(elem(picked, 0))
  end

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

    {0, vertices, faces, [], [], []}
  end

  def mesh(state) do
    current = state_or_initial(state)
    {current, surface_descriptor(current)}
  end

  def state_generation(state) do
    current = state_or_initial(state)
    {current, generation(current)}
  end

  def displayed_mesh_code(state) do
    current = state_or_initial(state)
    boxed = state_code_box(current)
    {current, elem(boxed, 0)}
  end

  def selected_triangle_indices(state) do
    current = state_or_initial(state)
    {current, selection_indices(selection(current))}
  end

  def editor_pointer_button(
        state,
        event_word,
        origin_x,
        origin_y,
        origin_z,
        direction_x,
        direction_y,
        direction_z
      )
      when is_integer(event_word) and is_integer(origin_x) and is_integer(origin_y) and
             is_integer(origin_z) and is_integer(direction_x) and is_integer(direction_y) and
             is_integer(direction_z) do
    current = state_or_initial(state)
    expected_generation = div(event_word, 256)
    flags = rem(event_word, 256)

    if generation(current) != expected_generation do
      {current, 1}
    else
      if rem(flags, 16) == 3 do
        apply_pick_from_ray(
          current,
          {origin_x, origin_y, origin_z},
          {direction_x, direction_y, direction_z}
        )
      else
        {current, 4}
      end
    end
  end

  def editor_move(state, dx, dy, dz, expected_generation, quota_bytes)
      when is_integer(dx) and is_integer(dy) and is_integer(dz) and
             is_integer(expected_generation) and is_integer(quota_bytes) do
    current = state_or_initial(state)
    result = move_selected(current, dx, dy, dz, expected_generation, quota_bytes)
    next = elem(result, 0)
    code = elem(result, 1)
    {next, if(code == 0, do: generation(next), else: negative(code))}
  end

  def editor_undo(state, expected_generation)
      when is_integer(expected_generation) do
    current = state_or_initial(state)
    result = undo(current, expected_generation)
    next = elem(result, 0)
    code = elem(result, 1)
    {next, if(code == 0, do: generation(next), else: negative(code))}
  end

  def editor_redo(state, expected_generation)
      when is_integer(expected_generation) do
    current = state_or_initial(state)
    result = redo(current, expected_generation)
    next = elem(result, 0)
    code = elem(result, 1)
    {next, if(code == 0, do: generation(next), else: negative(code))}
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
        {{generation, elem(state, 1), faces, [face_id], elem(state, 4), elem(state, 5)}, 0}
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
          if zero_vector_code(dx, dy, dz) == 1 do
            {state, 0}
          else
            commit_move(state, dx, dy, dz)
          end
        end
      end
    end
  end

  def undo(state, expected_generation) when is_integer(expected_generation) do
    if generation(state) != expected_generation do
      {state, 1}
    else
      undo_from_history(elem(state, 4), state)
    end
  end

  def redo(state, expected_generation) when is_integer(expected_generation) do
    if generation(state) != expected_generation do
      {state, 1}
    else
      redo_from_history(elem(state, 5), state)
    end
  end

  def generation(state), do: add_integer(elem(state, 0), 0)
  def vertices(state), do: elem(state, 1)
  def faces(state), do: elem(state, 2)
  def selection(state), do: elem(state, 3)

  def state_code(state) do
    encode_state_code(
      generation(state),
      selection_code(selection(state)),
      vertex_z_sum(vertices(state))
    )
  end

  defp state_code_box(state) do
    encode_state_code_box(
      generation(state),
      selection_code(selection(state)),
      vertex_z_sum(vertices(state))
    )
  end

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
    next = {increment(generation), moved, faces, selection, [previous | elem(state, 4)], []}

    if vertices_in_range(moved) do
      {next, 0}
    else
      {state, 4}
    end
  end

  defp undo_from_history([], state), do: {state, 5}

  defp undo_from_history([previous | rest], state) do
    current = state_snapshot(state)

    next =
      {increment(generation(state)), elem(previous, 1), elem(previous, 2), elem(previous, 3),
       rest, [current | elem(state, 5)]}

    {next, 0}
  end

  defp redo_from_history([], state), do: {state, 5}

  defp redo_from_history([following | rest], state) do
    current = state_snapshot(state)

    next =
      {increment(generation(state)), elem(following, 1), elem(following, 2), elem(following, 3),
       [current | elem(state, 4)], rest}

    {next, 0}
  end

  defp state_snapshot(state) do
    {generation(state), vertices(state), faces(state), selection(state)}
  end

  defp state_or_initial(nil), do: cube_state()
  defp state_or_initial(state) when is_tuple(state), do: state

  defp surface_descriptor(state) do
    {surface_vertices(vertices(state)),
     [
       0,
       3,
       2,
       0,
       2,
       1,
       4,
       5,
       6,
       4,
       6,
       7,
       0,
       1,
       5,
       0,
       5,
       4,
       1,
       2,
       6,
       1,
       6,
       5,
       2,
       3,
       7,
       2,
       7,
       6,
       3,
       0,
       4,
       3,
       4,
       7
     ], 1_000}
  end

  defp surface_vertices([]), do: []

  defp surface_vertices([vertex | rest]) do
    [{elem(vertex, 1), elem(vertex, 2), elem(vertex, 3)} | surface_vertices(rest)]
  end

  defp selection_indices([]), do: []
  defp selection_indices([face_id | _rest]), do: face_selection_indices(face_id)

  defp face_selection_indices(0), do: [0, 3, 2, 0, 2, 1]
  defp face_selection_indices(1), do: [4, 5, 6, 4, 6, 7]
  defp face_selection_indices(2), do: [0, 1, 5, 0, 5, 4]
  defp face_selection_indices(3), do: [1, 2, 6, 1, 6, 5]
  defp face_selection_indices(4), do: [2, 3, 7, 2, 7, 6]
  defp face_selection_indices(5), do: [3, 0, 4, 3, 4, 7]
  defp face_selection_indices(_face_id), do: []

  defp apply_pick(state, face_id)
       when is_integer(face_id) and face_id >= 0 and face_id <= 5,
       do:
         {{generation(state), vertices(state), faces(state), [face_id], elem(state, 4),
           elem(state, 5)}, 0}

  defp apply_pick(state, face_id) when is_integer(face_id), do: {state, 5}

  defp apply_pick_from_ray(state, origin, direction) do
    apply_pick(state, pick_face(state, origin, direction))
  end

  defp pick_face(state, ray_origin, ray_direction) do
    vertices = vertices(state)
    first = face_hit_distance(vertices, [0, 3, 2, 1], ray_origin, ray_direction)
    second = face_hit_distance(vertices, [4, 5, 6, 7], ray_origin, ray_direction)
    third = face_hit_distance(vertices, [0, 1, 5, 4], ray_origin, ray_direction)
    fourth = face_hit_distance(vertices, [1, 2, 6, 5], ray_origin, ray_direction)
    fifth = face_hit_distance(vertices, [2, 3, 7, 6], ray_origin, ray_direction)
    sixth = face_hit_distance(vertices, [3, 0, 4, 7], ray_origin, ray_direction)

    face_for_hit(first, second, third, fourth, fifth, sixth)
  end

  defp face_hit_distance(vertices, ids, origin, direction) do
    first = vertex_xyz(find_vertex(vertices, list_at(ids, 0)))
    second = vertex_xyz(find_vertex(vertices, list_at(ids, 1)))
    third = vertex_xyz(find_vertex(vertices, list_at(ids, 2)))
    fourth = vertex_xyz(find_vertex(vertices, list_at(ids, 3)))
    first_hit = ray_triangle_hit(origin, direction, first, second, third)
    second_hit = ray_triangle_hit(origin, direction, first, third, fourth)
    face_hit = nearer_hit(first_hit, second_hit)
    distance_code(elem(face_hit, 0), elem(face_hit, 1))
  end

  defp distance_code(numerator, denominator)
       when is_integer(numerator) and is_integer(denominator) and numerator == 0 and
              denominator == 0,
       do: 9_000_000_000_000_000

  defp distance_code(numerator, denominator)
       when is_integer(numerator) and is_integer(denominator),
       do: div(numerator, denominator)

  defp face_for_hit(first, second, third, fourth, fifth, sixth) do
    best =
      minimum_distance(
        first,
        minimum_distance(
          second,
          minimum_distance(third, minimum_distance(fourth, minimum_distance(fifth, sixth)))
        )
      )

    face_for_distance(best, first, second, third, fourth, fifth, sixth)
  end

  defp minimum_distance(left, right) when left <= right, do: left + 0
  defp minimum_distance(_left, right), do: right + 0

  defp face_for_distance(best, _first, _second, _third, _fourth, _fifth, _sixth)
       when best == 9_000_000_000_000_000,
       do: 6 + 0

  defp face_for_distance(best, first, _second, _third, _fourth, _fifth, _sixth)
       when best == first,
       do: 0 + 0

  defp face_for_distance(best, _first, second, _third, _fourth, _fifth, _sixth)
       when best == second,
       do: 1 + 0

  defp face_for_distance(best, _first, _second, third, _fourth, _fifth, _sixth)
       when best == third,
       do: 2 + 0

  defp face_for_distance(best, _first, _second, _third, fourth, _fifth, _sixth)
       when best == fourth,
       do: 3 + 0

  defp face_for_distance(best, _first, _second, _third, _fourth, fifth, _sixth)
       when best == fifth,
       do: 4 + 0

  defp face_for_distance(_best, _first, _second, _third, _fourth, _fifth, _sixth),
    do: 5 + 0

  defp ray_triangle_hit(origin, direction, first, second, third) do
    edge_one = vector_sub(second, first)
    edge_two = vector_sub(third, first)
    p = vector_cross(direction, edge_two)
    determinant = vector_dot(edge_one, p)
    triangle_with_determinant(origin, direction, first, edge_one, edge_two, p, determinant)
  end

  defp triangle_with_determinant(origin, direction, first, edge_one, edge_two, p, determinant)
       when determinant < 0 do
    translated = vector_sub(origin, first)
    u = vector_dot(translated, p)
    triangle_with_u(direction, edge_one, edge_two, translated, determinant, u)
  end

  defp triangle_with_determinant(origin, direction, first, edge_one, edge_two, p, determinant)
       when determinant > 0 do
    translated = vector_sub(origin, first)
    u = vector_dot(translated, p)
    triangle_with_positive_u(direction, edge_one, edge_two, translated, determinant, u)
  end

  defp triangle_with_determinant(
         _origin,
         _direction,
         _first,
         _edge_one,
         _edge_two,
         _p,
         _determinant
       ),
       do: {0, 0}

  defp triangle_with_u(direction, edge_one, edge_two, translated, determinant, u)
       when u <= 0 and u >= determinant do
    q = vector_cross(translated, edge_one)
    v = vector_dot(direction, q)
    triangle_with_v(edge_two, q, determinant, u, v)
  end

  defp triangle_with_u(_direction, _edge_one, _edge_two, _translated, _determinant, _u),
    do: {0, 0}

  defp triangle_with_v(edge_two, q, determinant, u, v)
       when v <= 0 and u + v >= determinant do
    hit_fraction(vector_dot(edge_two, q), determinant)
  end

  defp triangle_with_v(_edge_two, _q, _determinant, _u, _v), do: {0, 0}

  defp triangle_with_positive_u(direction, edge_one, edge_two, translated, determinant, u)
       when u >= 0 and u <= determinant do
    q = vector_cross(translated, edge_one)
    v = vector_dot(direction, q)
    triangle_with_positive_v(edge_two, q, determinant, u, v)
  end

  defp triangle_with_positive_u(
         _direction,
         _edge_one,
         _edge_two,
         _translated,
         _determinant,
         _u
       ),
       do: {0, 0}

  defp triangle_with_positive_v(edge_two, q, determinant, u, v)
       when v >= 0 and u + v <= determinant do
    positive_hit_fraction(vector_dot(edge_two, q), determinant)
  end

  defp triangle_with_positive_v(_edge_two, _q, _determinant, _u, _v), do: {0, 0}

  defp hit_fraction(numerator, denominator) when numerator < 0,
    do: {negative(numerator), negative(denominator)}

  defp hit_fraction(_numerator, _denominator), do: {0, 0}

  defp positive_hit_fraction(numerator, denominator) when numerator > 0,
    do: {numerator, denominator}

  defp positive_hit_fraction(_numerator, _denominator), do: {0, 0}

  defp nearer_hit({0, 0}, right), do: right
  defp nearer_hit(left, {0, 0}), do: left

  defp nearer_hit(left, right) do
    if fraction_less(elem(left, 0), elem(left, 1), elem(right, 0), elem(right, 1)) == 1,
      do: left,
      else: right
  end

  defp fraction_less(left_numerator, left_denominator, right_numerator, right_denominator) do
    left = mul_integer(left_numerator, right_denominator)
    right = mul_integer(right_numerator, left_denominator)
    less_than_code(left, right)
  end

  defp less_than_code(left, right) when left < right, do: 1
  defp less_than_code(_left, _right), do: 0

  defp vertex_xyz(vertex) do
    {elem(vertex, 1), elem(vertex, 2), elem(vertex, 3)}
  end

  defp vector_sub(left, right) do
    {sub_integer(elem(left, 0), elem(right, 0)), sub_integer(elem(left, 1), elem(right, 1)),
     sub_integer(elem(left, 2), elem(right, 2))}
  end

  defp vector_cross(left, right) do
    {sub_integer(
       mul_integer(elem(left, 1), elem(right, 2)),
       mul_integer(elem(left, 2), elem(right, 1))
     ),
     sub_integer(
       mul_integer(elem(left, 2), elem(right, 0)),
       mul_integer(elem(left, 0), elem(right, 2))
     ),
     sub_integer(
       mul_integer(elem(left, 0), elem(right, 1)),
       mul_integer(elem(left, 1), elem(right, 0))
     )}
  end

  defp vector_dot(left, right) do
    add_integer(
      add_integer(
        mul_integer(elem(left, 0), elem(right, 0)),
        mul_integer(elem(left, 1), elem(right, 1))
      ),
      mul_integer(elem(left, 2), elem(right, 2))
    )
  end

  defp list_at([value | _rest], 0), do: value
  defp list_at([_value | rest], index), do: list_at(rest, index - 1)

  defp selection_code([]), do: 0
  defp selection_code([0 | _rest]), do: 0
  defp selection_code([1 | _rest]), do: 1
  defp selection_code([2 | _rest]), do: 2
  defp selection_code([3 | _rest]), do: 3
  defp selection_code([4 | _rest]), do: 4
  defp selection_code([5 | _rest]), do: 5
  defp selection_code([_face_id | _rest]), do: 9

  defp vertex_z_sum([]), do: 0
  defp vertex_z_sum([vertex | rest]), do: add_integer(elem(vertex, 3), vertex_z_sum(rest))

  defp face_exists([], _face_id), do: false

  defp face_exists([face | rest], face_id) do
    if elem(face, 0) == face_id, do: true, else: face_exists(rest, face_id)
  end

  defp find_vertex([], _vertex_id), do: {}

  defp find_vertex([vertex | rest], vertex_id) do
    if elem(vertex, 0) == vertex_id, do: vertex, else: find_vertex(rest, vertex_id)
  end

  defp vertices_in_range([]), do: true

  defp vertices_in_range([vertex | rest]) do
    if coordinate_in_range(elem(vertex, 1)) do
      if coordinate_in_range(elem(vertex, 2)) do
        if coordinate_in_range(elem(vertex, 3)), do: vertices_in_range(rest), else: false
      else
        false
      end
    else
      false
    end
  end

  defp coordinate_in_range(value) when value < -1_000_000, do: false
  defp coordinate_in_range(value) when value > 1_000_000, do: false
  defp coordinate_in_range(value) when is_integer(value), do: true

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

  defp encode_state_code(generation, selected_face, z_sum)
       when is_integer(generation) and is_integer(selected_face) and is_integer(z_sum) do
    generation * 1_000_000 + selected_face * 100_000 + z_sum
  end

  defp encode_state_code_box(generation, selected_face, z_sum)
       when is_integer(generation) and is_integer(selected_face) and is_integer(z_sum) do
    {generation * 1_000_000 + selected_face * 100_000 + z_sum}
  end

  defp add_integer(left, right) when is_integer(left) and is_integer(right), do: left + right
  defp sub_integer(left, right) when is_integer(left) and is_integer(right), do: left - right
  defp mul_integer(left, right) when is_integer(left) and is_integer(right), do: left * right
  defp increment(value) when is_integer(value), do: value + 1
  defp negative(value) when is_integer(value), do: 0 - value
  defp half_even(value), do: half_even(value, 0)
  defp half_even(0, result), do: result

  defp half_even(value, result) when is_integer(value) and is_integer(result) and value > 0 do
    half_even(value - 2, result + 1)
  end

  defp zero_vector_code(dx, dy, dz)
       when is_integer(dx) and is_integer(dy) and is_integer(dz) do
    if dx == 0, do: if(dy == 0, do: if(dz == 0, do: 1, else: 0), else: 0), else: 0
  end

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
