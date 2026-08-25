defmodule Batata.Wings.Godot.EditorPlugin do
  @moduledoc false

  @relative_dir "addons/batata_wings_editor"

  @spec write!(Path.t()) :: map()
  def write!(output_dir) do
    directory = Path.join(output_dir, @relative_dir)
    File.mkdir_p!(directory)
    config = Path.join(directory, "plugin.cfg")
    script = Path.join(directory, "plugin.gd")
    File.write!(config, config_source())
    File.write!(script, script_source())

    %{
      config: config,
      config_sha256: digest(config_source()),
      script: script,
      script_sha256: digest(script_source())
    }
  end

  defp config_source do
    """
    [plugin]
    name="Batata Wings Editor"
    description="Closed editor input adapter for Batata Wings"
    author="Batata"
    version="0.1.0-dev"
    script="plugin.gd"
    """
  end

  defp script_source do
    """
    @tool
    extends EditorPlugin

    var controller
    var edit_target
    var editor_visible := false

    func _enter_tree():
      controller = ClassDB.instantiate("BatataWingsMesh")
      if controller == null:
        push_error("E_GODOT_EDITOR_STATE_UNAVAILABLE: controller creation failed")
        return
      var observed = controller.editor_pointer_button(
        Vector2(640.0, 360.0), 1, true, 0,
        Vector3(0.0, 0.0, 5.0), Vector3(0.0, 0.0, -1.0), 0)
      if observed != 0:
        push_error("E_GODOT_EDITOR_STATE_STALE: typed replay generation differs")
        return
      var marker = FileAccess.open("res://.batata/editor-plugin-ready", FileAccess.WRITE)
      if marker == null:
        push_error("E_GODOT_EDITOR_STATE_UNAVAILABLE: editor plugin marker failed")
        return
      marker.store_string("ready")
      marker.close()

    func _exit_tree():
      edit_target = null
      controller = null

    func _handles(object):
      return object is MeshInstance3D

    func _edit(object):
      edit_target = object if _handles(object) else null

    func _make_visible(visible):
      editor_visible = visible

    func _forward_3d_gui_input(viewport_camera, event):
      if controller == null or not editor_visible:
        return EditorPlugin.AFTER_GUI_INPUT_PASS

      if event is InputEventMouseButton:
        var modifiers = _modifier_mask(event)
        var generation = controller.state_generation()
        controller.editor_pointer_button(
          event.position, event.button_index, event.pressed, modifiers,
          viewport_camera.project_ray_origin(event.position),
          viewport_camera.project_ray_normal(event.position), generation)
        return EditorPlugin.AFTER_GUI_INPUT_STOP

      if event is InputEventKey and event.pressed and event.keycode in [KEY_Z, KEY_Y]:
        controller.editor_key_chord(
          event.keycode, _modifier_mask(event), event.pressed,
          controller.state_generation())
        return EditorPlugin.AFTER_GUI_INPUT_STOP

      return EditorPlugin.AFTER_GUI_INPUT_PASS

    func _modifier_mask(event):
      var mask := 0
      if event.shift_pressed:
        mask |= 1
      if event.ctrl_pressed:
        mask |= 2
      if event.meta_pressed:
        mask |= 4
      if event.alt_pressed:
        mask |= 8
      return mask
    """
  end

  defp digest(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
