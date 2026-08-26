defmodule Batata.Wings.Native.Kernel do
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting
  # credo:disable-for-this-file Credo.Check.Readability.ParenthesesOnZeroArityDefs
  @moduledoc false

  def main(), do: {native_editor_smoke_code(), native_topology_edit_smoke_code()}

  def native_editor_smoke_code() do
    picked = editor_pointer_button(nil, 3, 0, 0, 5_000, 0, 0, -10)
    state_code(elem(picked, 0))
  end

  def native_topology_edit_smoke_code() do
    selected = elem(select_face(cube_state(), 1, 0), 0)
    extruded = elem(extrude_selected(selected, 250, 0, 4_096), 0)
    individual = elem(extrude_individual_selected(extruded, 250, 1, 4_096), 0)
    inset = elem(inset_selected(individual, 250, 2, 4_096), 0)
    beveled = elem(bevel_selected(inset, 100, 50, 3, 4_096), 0)
    layout_code(beveled)
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

  def editor_layout_code(state) do
    current = state_or_initial(state)
    {current, layout_code(current)}
  end

  def selected_triangle_indices(state) do
    current = state_or_initial(state)
    {current, selection_indices(selection(current), faces(current))}
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

  def editor_extrude(state, distance, expected_generation, quota_bytes)
      when is_integer(distance) and is_integer(expected_generation) and is_integer(quota_bytes) do
    current = state_or_initial(state)
    result = extrude_selected(current, distance, expected_generation, quota_bytes)
    next = elem(result, 0)
    code = elem(result, 1)
    {next, if(code == 0, do: generation(next), else: negative(code))}
  end

  def editor_extrude_individual(state, distance, expected_generation, quota_bytes)
      when is_integer(distance) and is_integer(expected_generation) and is_integer(quota_bytes) do
    current = state_or_initial(state)
    result = extrude_individual_selected(current, distance, expected_generation, quota_bytes)
    next = elem(result, 0)
    code = elem(result, 1)
    {next, if(code == 0, do: generation(next), else: negative(code))}
  end

  def editor_inset(state, ratio_milli, expected_generation, quota_bytes)
      when is_integer(ratio_milli) and is_integer(expected_generation) and
             is_integer(quota_bytes) do
    current = state_or_initial(state)
    result = inset_selected(current, ratio_milli, expected_generation, quota_bytes)
    next = elem(result, 0)
    code = elem(result, 1)
    {next, if(code == 0, do: generation(next), else: negative(code))}
  end

  def editor_bevel(state, ratio_milli, width, expected_generation, quota_bytes)
      when is_integer(ratio_milli) and is_integer(width) and
             is_integer(expected_generation) and is_integer(quota_bytes) do
    current = state_or_initial(state)
    result = bevel_selected(current, ratio_milli, width, expected_generation, quota_bytes)
    next = elem(result, 0)
    code = elem(result, 1)
    {next, if(code == 0, do: generation(next), else: negative(code))}
  end

  def topology_stats(state) do
    vertices = elem(state, 1)
    faces = elem(state, 2)
    vertex_count = add_integer(length(vertices), 0)
    face_count = add_integer(length(faces), 0)
    side_count = mul_integer(face_count, 4)
    edge_count = mul_integer(face_count, 2)

    {closed_boolean(valid_closed_layout(vertex_count, side_count, face_count)), vertex_count,
     edge_count, face_count, euler_characteristic(vertex_count, edge_count, face_count)}
  end

  def vertex_count(state), do: length(elem(state, 1))
  def face_count(state), do: length(elem(state, 2))

  def layout_code(state) do
    encode_layout(length(elem(state, 1)), length(elem(state, 2)))
  end

  def topology_code_for_state(state) do
    encode_quad_topology(length(elem(state, 1)), length(elem(state, 2)))
  end

  defp encode_quad_topology(vertex_count, face_count)
       when is_integer(vertex_count) and is_integer(face_count) do
    edge_count = face_count * 2
    euler = vertex_count - edge_count + face_count

    if vertex_count == face_count + 2,
      do: vertex_count * 100_000 + edge_count * 1_000 + face_count * 10 + euler,
      else: -1
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

  def extrude_selected(state, distance, expected_generation, quota_bytes)
      when is_integer(distance) and is_integer(expected_generation) and is_integer(quota_bytes) do
    edit_selected_quad(state, 0, distance, 0, expected_generation, quota_bytes)
  end

  def extrude_individual_selected(state, distance, expected_generation, quota_bytes)
      when is_integer(distance) and is_integer(expected_generation) and is_integer(quota_bytes) do
    edit_selected_quad(state, 0, distance, 0, expected_generation, quota_bytes)
  end

  def inset_selected(state, ratio_milli, expected_generation, quota_bytes)
      when is_integer(ratio_milli) and is_integer(expected_generation) and
             is_integer(quota_bytes) do
    edit_selected_quad(state, ratio_milli, 0, 1, expected_generation, quota_bytes)
  end

  def bevel_selected(state, ratio_milli, width, expected_generation, quota_bytes)
      when is_integer(ratio_milli) and is_integer(width) and
             is_integer(expected_generation) and is_integer(quota_bytes) do
    edit_selected_quad(state, ratio_milli, width, 2, expected_generation, quota_bytes)
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

  defp valid_closed_layout(vertex_count, side_count, face_count) do
    if side_count == mul_integer(face_count, 4) do
      if vertex_count == add_integer(face_count, 2), do: 1, else: 0
    else
      0
    end
  end

  defp closed_boolean(1), do: true
  defp closed_boolean(_code), do: false

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

  defp edit_selected_quad(
         state,
         ratio_milli,
         distance,
         operation,
         expected_generation,
         quota_bytes
       ) do
    face_id = single_selection_id(selection(state))
    estimate = add_integer(estimate_bytes(vertices(state), faces(state)), 384)

    if generation(state) != expected_generation do
      {state, 1}
    else
      if face_id < 0 do
        {state, 2}
      else
        if valid_edit_parameters(ratio_milli, distance, operation) == 0 do
          {state, 6}
        else
          if estimate > quota_bytes do
            {state, 3}
          else
            build_quad_edit(state, face_id, ratio_milli, distance, operation)
          end
        end
      end
    end
  end

  defp build_quad_edit(state, face_id, ratio_milli, distance, operation) do
    old_vertices = vertices(state)
    old_faces = faces(state)
    source_face = find_face(old_faces, face_id)
    source_ids = elem(source_face, 1)
    first_vertex = length(old_vertices)

    duplicate_ids = [
      first_vertex,
      add_integer(first_vertex, 1),
      add_integer(first_vertex, 2),
      add_integer(first_vertex, 3)
    ]

    center = quad_centroid(old_vertices, source_ids)

    normal_offset =
      axis_offset(old_vertices, source_ids, edit_normal_distance(operation, distance))

    additions =
      transformed_quad_vertices(
        old_vertices,
        source_ids,
        duplicate_ids,
        center,
        ratio_milli,
        normal_offset
      )

    candidate_vertices =
      append_four_terms(
        old_vertices,
        list_at(additions, 0),
        list_at(additions, 1),
        list_at(additions, 2),
        list_at(additions, 3)
      )

    cap_faces = replace_face(old_faces, face_id, duplicate_ids)
    side_faces = quad_side_faces(source_ids, duplicate_ids, length(old_faces))

    candidate_faces =
      append_four_terms(
        cap_faces,
        list_at(side_faces, 0),
        list_at(side_faces, 1),
        list_at(side_faces, 2),
        list_at(side_faces, 3)
      )

    commit_topology_edit(state, candidate_vertices, candidate_faces)
  end

  defp commit_topology_edit(state, candidate_vertices, candidate_faces) do
    vertex_count = length(candidate_vertices)
    face_count = length(candidate_faces)

    if vertex_count == add_integer(face_count, 2) do
      commit_candidate_if_in_range(state, candidate_vertices, candidate_faces)
    else
      {state, 7}
    end
  end

  defp commit_candidate_if_in_range(state, candidate_vertices, candidate_faces)
       when is_list(candidate_vertices) and is_list(candidate_faces) do
    previous = state_snapshot(state)

    next =
      {increment(generation(state)), candidate_vertices, candidate_faces, selection(state),
       [previous | elem(state, 4)], []}

    if vertices_in_range(candidate_vertices), do: {next, 0}, else: {state, 4}
  end

  defp single_selection_id([]), do: -1

  defp single_selection_id([face_id | rest]) when is_integer(face_id) do
    single_selection_tail(rest, face_id)
  end

  defp single_selection_tail([], face_id) when is_integer(face_id), do: face_id + 0
  defp single_selection_tail([_extra | _rest], _face_id), do: -1

  defp valid_edit_parameters(ratio, distance, operation)
       when is_integer(ratio) and is_integer(distance) and is_integer(operation) do
    if operation == 0 do
      positive_bounded_code(distance, 100_000)
    else
      if operation == 1 do
        positive_bounded_code(ratio, 490)
      else
        if operation == 2 do
          if positive_bounded_code(ratio, 490) == 1,
            do: positive_bounded_code(distance, 100_000),
            else: 0
        else
          0
        end
      end
    end
  end

  defp positive_bounded_code(value, _maximum) when value <= 0, do: 0
  defp positive_bounded_code(value, maximum) when value > maximum, do: 0
  defp positive_bounded_code(_value, _maximum), do: 1

  defp edit_normal_distance(0, distance), do: distance + 0
  defp edit_normal_distance(1, _distance), do: 0
  defp edit_normal_distance(2, width), do: negative(width)

  defp quad_centroid(vertices, ids) do
    first = vertex_xyz(find_vertex(vertices, list_at(ids, 0)))
    second = vertex_xyz(find_vertex(vertices, list_at(ids, 1)))
    third = vertex_xyz(find_vertex(vertices, list_at(ids, 2)))
    fourth = vertex_xyz(find_vertex(vertices, list_at(ids, 3)))

    {average_four(elem(first, 0), elem(second, 0), elem(third, 0), elem(fourth, 0)),
     average_four(elem(first, 1), elem(second, 1), elem(third, 1), elem(fourth, 1)),
     average_four(elem(first, 2), elem(second, 2), elem(third, 2), elem(fourth, 2))}
  end

  defp average_four(first, second, third, fourth)
       when is_integer(first) and is_integer(second) and is_integer(third) and is_integer(fourth) do
    div(add_integer(add_integer(first, second), add_integer(third, fourth)), 4)
  end

  defp axis_offset(vertices, ids, distance) do
    first = vertex_xyz(find_vertex(vertices, list_at(ids, 0)))
    second = vertex_xyz(find_vertex(vertices, list_at(ids, 1)))
    third = vertex_xyz(find_vertex(vertices, list_at(ids, 2)))
    normal = vector_cross(vector_sub(second, first), vector_sub(third, second))

    dominant_axis_offset(
      elem(normal, 0),
      elem(normal, 1),
      elem(normal, 2),
      distance
    )
  end

  defp dominant_axis_offset(x, y, z, distance) do
    ax = absolute_integer(x)
    ay = absolute_integer(y)
    az = absolute_integer(z)

    if ax >= ay do
      if ax >= az,
        do: {signed_distance(x, distance), 0, 0},
        else: {0, 0, signed_distance(z, distance)}
    else
      if ay >= az,
        do: {0, signed_distance(y, distance), 0},
        else: {0, 0, signed_distance(z, distance)}
    end
  end

  defp signed_distance(value, distance) when value < 0, do: negative(distance)
  defp signed_distance(_value, distance), do: distance + 0

  defp absolute_integer(value) when value < 0, do: negative(value)
  defp absolute_integer(value), do: value + 0

  defp transformed_quad_vertices(
         vertices,
         source_ids,
         duplicate_ids,
         center,
         ratio_milli,
         offset
       ) do
    [
      transformed_vertex(vertices, source_ids, duplicate_ids, 0, center, ratio_milli, offset),
      transformed_vertex(vertices, source_ids, duplicate_ids, 1, center, ratio_milli, offset),
      transformed_vertex(vertices, source_ids, duplicate_ids, 2, center, ratio_milli, offset),
      transformed_vertex(vertices, source_ids, duplicate_ids, 3, center, ratio_milli, offset)
    ]
  end

  defp transformed_vertex(vertices, source_ids, duplicate_ids, index, center, ratio_milli, offset) do
    source = find_vertex(vertices, list_at(source_ids, index))
    point = vertex_xyz(source)
    scaled = scale_toward_center(point, center, ratio_milli)

    {list_at(duplicate_ids, index), add_integer(elem(scaled, 0), elem(offset, 0)),
     add_integer(elem(scaled, 1), elem(offset, 1)), add_integer(elem(scaled, 2), elem(offset, 2))}
  end

  defp scale_toward_center(point, center, ratio_milli) do
    keep = sub_integer(1_000, ratio_milli)

    {scaled_component(elem(point, 0), elem(center, 0), keep),
     scaled_component(elem(point, 1), elem(center, 1), keep),
     scaled_component(elem(point, 2), elem(center, 2), keep)}
  end

  defp scaled_component(point, center, keep)
       when is_integer(point) and is_integer(center) and is_integer(keep) do
    add_integer(center, div(mul_integer(sub_integer(point, center), keep), 1_000))
  end

  defp replace_face([], _face_id, new_vertices) when is_list(new_vertices), do: []

  defp replace_face([face | rest], face_id, new_vertices) when is_list(new_vertices) do
    if elem(face, 0) == face_id,
      do: [{face_id, new_vertices} | rest],
      else: [face | replace_face(rest, face_id, new_vertices)]
  end

  defp quad_side_faces(source, duplicate, first_face) do
    [
      {first_face,
       [list_at(source, 0), list_at(source, 1), list_at(duplicate, 1), list_at(duplicate, 0)]},
      {add_integer(first_face, 1),
       [list_at(source, 1), list_at(source, 2), list_at(duplicate, 2), list_at(duplicate, 1)]},
      {add_integer(first_face, 2),
       [list_at(source, 2), list_at(source, 3), list_at(duplicate, 3), list_at(duplicate, 2)]},
      {add_integer(first_face, 3),
       [list_at(source, 3), list_at(source, 0), list_at(duplicate, 0), list_at(duplicate, 3)]}
    ]
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
    {surface_vertices(vertices(state)), surface_indices(faces(state)), 1_000}
  end

  defp surface_vertices([]), do: []

  defp surface_vertices([vertex | rest]) do
    [{elem(vertex, 1), elem(vertex, 2), elem(vertex, 3)} | surface_vertices(rest)]
  end

  defp surface_indices([]), do: []

  defp surface_indices([face | rest]) do
    prepend_face_triangles(elem(face, 1), surface_indices(rest))
  end

  defp prepend_face_triangles(vertices, tail) when is_list(vertices) and is_list(tail) do
    first = list_at(vertices, 0)
    second = list_at(vertices, 1)
    third = list_at(vertices, 2)
    fourth = list_at(vertices, 3)
    tail = prepend_term(fourth, tail)
    tail = prepend_term(third, tail)
    tail = prepend_term(first, tail)
    tail = prepend_term(third, tail)
    tail = prepend_term(second, tail)
    prepend_term(first, tail)
  end

  defp triangulate_face(vertices) when is_list(vertices) do
    if length(vertices) == 4 do
      triangulate_quad(vertices)
    else
      []
    end
  end

  defp triangulate_quad(vertices) when is_list(vertices) do
    first = list_at(vertices, 0)
    second = list_at(vertices, 1)
    third = list_at(vertices, 2)
    fourth = list_at(vertices, 3)
    [first, second, third, first, third, fourth]
  end

  defp selection_indices([], _faces), do: []

  defp selection_indices([face_id | _rest], faces) do
    triangulate_face(elem(find_face(faces, face_id), 1))
  end

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

  defp list_at([_value | rest], index) when is_integer(index),
    do: list_at(rest, index - 1)

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

  defp find_vertex([], vertex_id) when is_integer(vertex_id), do: {}

  defp find_vertex([vertex | rest], vertex_id) when is_integer(vertex_id) do
    if elem(vertex, 0) == vertex_id, do: vertex, else: find_vertex(rest, vertex_id)
  end

  defp find_face([], face_id) when is_integer(face_id), do: {}

  defp find_face([face | rest], face_id) when is_integer(face_id) do
    if elem(face, 0) == face_id, do: face, else: find_face(rest, face_id)
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
    estimate_counts(length(vertices), length(faces))
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
    encode_topology_values(vertices, edges, faces, euler)
  end

  defp encode_topology(false, _vertices, _edges, _faces, _euler), do: -1

  defp encode_topology(1, vertices, edges, faces, euler)
       when is_integer(vertices) and is_integer(edges) and is_integer(faces) and
              is_integer(euler) do
    encode_topology_values(vertices, edges, faces, euler)
  end

  defp encode_topology(0, _vertices, _edges, _faces, _euler), do: -1

  defp encode_topology_values(vertices, edges, faces, euler)
       when is_integer(vertices) and is_integer(edges) and is_integer(faces) and
              is_integer(euler) do
    vertices * 100_000 + edges * 1_000 + faces * 10 + euler
  end

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

  defp zero_vector_code(dx, dy, dz)
       when is_integer(dx) and is_integer(dy) and is_integer(dz) do
    if dx == 0, do: if(dy == 0, do: if(dz == 0, do: 1, else: 0), else: 0), else: 0
  end

  defp greater_than(left, right) when left > right, do: true
  defp greater_than(_left, _right), do: false
  defp list_member([], value) when is_integer(value), do: false

  defp list_member([head | rest], value) when is_integer(head) and is_integer(value) do
    if head == value, do: true, else: list_member(rest, value)
  end

  defp append_four_terms([], first, second, third, fourth)
       when is_tuple(first) and is_tuple(second) and is_tuple(third) and is_tuple(fourth),
       do: [first, second, third, fourth]

  defp append_four_terms([head | rest], first, second, third, fourth)
       when is_tuple(first) and is_tuple(second) and is_tuple(third) and is_tuple(fourth),
       do: [head | append_four_terms(rest, first, second, third, fourth)]

  defp prepend_term(value, tail) when is_list(tail), do: [value | tail]
end
