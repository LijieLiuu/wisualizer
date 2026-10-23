extends SceneTree
## Draws the app's artwork from the files in assets/:
## - splash.png, the boot splash, with the main window's proportions at twice
##   its size;
## - icon_back.png and icon_front.png, the layers of the visionOS app icon;
## - icon.png, both layers in one, for the other platforms;
## - icon_macos.png, icon.png on the macOS icon grid: macOS shows an icon as
##   it is, so the rounded square, its margin and its shadow are drawn in.
## Run it from the project folder:
##   godot --path . -s branding/generate.gd

const ASSETS := "res://branding/assets/"
const OUTPUT := "res://branding/"
const ICON_SIZE := 1024
## The photo is blurred at this width, in pixels, by a Gaussian of this
## standard deviation.
const BLUR_WIDTH := 240
const BLUR_RADIUS := 7.0
## Apple's macOS icon grid, for a 1024-pixel icon: an 824-pixel rounded
## square with corners of this radius, centered, with a soft shadow below.
const MACOS_BODY := 824
const MACOS_RADIUS := 185.0
const MACOS_SHADOW := Color(0, 0, 0, 0.3)

var _frames := 0
## Viewports by the file each one is saved to.
var _outputs := {}


func _initialize() -> void:
	var window := Vector2i(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height"))
	_add("splash.png", window * 2, Art.Kind.SPLASH)
	_add("icon_back.png", Vector2i.ONE * ICON_SIZE, Art.Kind.ICON_BACK)
	_add("icon_front.png", Vector2i.ONE * ICON_SIZE, Art.Kind.ICON_FRONT)
	_add("icon.png", Vector2i.ONE * ICON_SIZE, Art.Kind.ICON)


func _add(file: String, size: Vector2i, kind: Art.Kind) -> void:
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.transparent_bg = kind == Art.Kind.ICON_FRONT
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var art := Art.new()
	art.kind = kind
	art.size = size
	viewport.add_child(art)
	root.add_child(viewport)
	_outputs[file] = viewport


func _process(_delta: float) -> bool:
	# Fonts and textures are uploaded over the first frames.
	_frames += 1
	if _frames < 10:
		return false
	for file in _outputs:
		var image: Image = _outputs[file].get_texture().get_image()
		_save(file, image)
		if file == "icon.png":
			_save("icon_macos.png", _macos_icon(image))
	return true


func _save(file: String, image: Image) -> void:
	var path: String = OUTPUT + file
	image.save_png(path)
	print("Wrote ", ProjectSettings.globalize_path(path))


## [param icon] shrunk onto the macOS grid: rounded, with a margin, and a
## shadow that falls a little below it.
static func _macos_icon(icon: Image) -> Image:
	var body := icon.duplicate() as Image
	body.convert(Image.FORMAT_RGBA8)
	body.resize(MACOS_BODY, MACOS_BODY, Image.INTERPOLATE_LANCZOS)
	var out := Image.create_empty(ICON_SIZE, ICON_SIZE, false, Image.FORMAT_RGBA8)
	var corner := (ICON_SIZE - MACOS_BODY) / 2
	var shadow_blur := 18.0
	var shadow_drop := 10.0
	for y in ICON_SIZE:
		for x in ICON_SIZE:
			var point := Vector2(x + 0.5, y + 0.5) - Vector2(corner, corner)
			var inside := _rounded_coverage(point, MACOS_BODY, MACOS_RADIUS)
			var shadow := clampf(0.5 - _rounded_distance(point - Vector2(0, shadow_drop), MACOS_BODY, MACOS_RADIUS) / (shadow_blur * 2.0), 0.0, 1.0)
			var color := Color(MACOS_SHADOW, MACOS_SHADOW.a * shadow * shadow)
			if inside > 0.0:
				var pixel := body.get_pixel(clampi(int(point.x), 0, MACOS_BODY - 1), clampi(int(point.y), 0, MACOS_BODY - 1))
				color = color.blend(Color(pixel, inside))
			out.set_pixel(x, y, color)
	return out


## How far [param point] is outside a rounded square of side [param side]
## and corner [param radius] at the origin; negative inside.
static func _rounded_distance(point: Vector2, side: float, radius: float) -> float:
	var half := Vector2(side, side) * 0.5
	var q := (point - half).abs() - half + Vector2(radius, radius)
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - radius


## How much of the pixel at [param point] the rounded square covers.
static func _rounded_coverage(point: Vector2, side: float, radius: float) -> float:
	return clampf(0.5 - _rounded_distance(point, side, radius), 0.0, 1.0)


class Art:
	extends Control

	enum Kind {
		SPLASH,
		ICON_BACK,
		ICON_FRONT,
		ICON,
	}

	var kind := Kind.SPLASH
	# Kept for as long as the art is drawn: the canvas only refers to them.
	var _kept: Array = []

	func _draw() -> void:
		var w := size.x
		var h := size.y
		match kind:
			Kind.SPLASH:
				_draw_backdrop()
				var font_size := int(w * 0.15)
				_draw_name("isualizer", Vector2(w * 0.5, h * 0.42), font_size)
				_draw_credits()
			Kind.ICON_BACK:
				_draw_backdrop()
			Kind.ICON_FRONT:
				# visionOS shades the layers itself.
				_draw_name("", Vector2(w * 0.5, h * 0.5), int(w * 0.5), false)
			Kind.ICON:
				_draw_backdrop()
				_draw_name("", Vector2(w * 0.5, h * 0.5), int(w * 0.5))

	## A blurred, muted campus photo behind a navy veil, darker toward the bottom.
	func _draw_backdrop() -> void:
		var photo := Image.load_from_file(ProjectSettings.globalize_path(ASSETS + "campus-preview.jpg"))
		photo.adjust_bcs(1.0, 1.0, 0.65)
		var cover := maxf(size.x / photo.get_width(), size.y / photo.get_height())
		var shown := Vector2(photo.get_width(), photo.get_height()) * cover
		# Blur at a fixed working size, so the blur looks the same at any output size.
		photo.convert(Image.FORMAT_RGBA8)
		photo.resize(BLUR_WIDTH, int(BLUR_WIDTH * photo.get_height() / float(photo.get_width())), Image.INTERPOLATE_LANCZOS)
		photo = _gaussian_blur(photo, BLUR_RADIUS)
		photo.resize(int(shown.x), int(shown.y), Image.INTERPOLATE_CUBIC)
		draw_texture_rect(_keep(ImageTexture.create_from_image(photo)), Rect2((size - shown) * Vector2(0.58, 0.5), shown), false)
		draw_rect(Rect2(Vector2.ZERO, size), Color8(17, 32, 48, 100))
		var shade := Gradient.new()
		shade.set_color(0, Color8(6, 16, 29, 25))
		shade.set_color(1, Color8(6, 16, 29, 120))
		var shade_texture := _keep(GradientTexture2D.new()) as GradientTexture2D
		shade_texture.gradient = shade
		shade_texture.fill_to = Vector2(0, 1)
		draw_texture_rect(shade_texture, Rect2(Vector2.ZERO, size), false)

	## The name centered on [param center], its W made of two overlapping
	## cursive Vs, as on the old splash; [param rest] follows the W.
	func _draw_name(rest: String, center: Vector2, font_size: int, shadow := true) -> void:
		var script := _font(ASSETS + "Courgette-Regular.ttf")
		var advance := script.get_string_size("V", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var second := advance * 0.74
		var rest_x := second + advance - font_size * 0.04
		var width := second + advance
		if not rest.is_empty():
			width = rest_x + script.get_string_size(rest, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		# Center the letters' ink, not the line: cursive capitals sit high.
		var baseline := Vector2(center.x - width * 0.5, center.y + script.get_ascent(font_size) * 0.5)
		if rest.is_empty():
			# The slanted Vs' ink leans right of their advance.
			baseline += Vector2(-0.11, -0.08) * font_size
		var parts := [[0.0, "V", Color("#A6B9C9")], [second, "V", Color("#E3D9B8")]]
		if not rest.is_empty():
			parts.append([rest_x, rest, Color("#F3F1EA")])
		# A soft shadow: the text drawn faintly many times around a lower point.
		for step in 24 if shadow else 0:
			var offset := Vector2.from_angle(TAU * step / 24.0) * font_size * 0.05 + Vector2(0, font_size * 0.035)
			for part in parts:
				draw_string(script, baseline + Vector2(part[0], 0) + offset, part[1], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.04))
		for part in parts:
			draw_string(script, baseline + Vector2(part[0], 0), part[1], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, part[2])

	## Credits, centered at the bottom under the Godot logo.
	func _draw_credits() -> void:
		var w := size.x
		var lines := FileAccess.get_file_as_string(OUTPUT + "captions.txt").strip_edges().split("\n")
		var margin := w * 0.06
		var label := _font("res://ui/fonts/Inter.ttf")
		var label_size := int(w * 0.022)
		var line_height := label.get_height(label_size) * 1.3
		var y := size.y - margin - line_height * lines.size()
		var logo := Image.load_from_file(ProjectSettings.globalize_path(ASSETS + "godot-large-horizontal-dark.png"))
		var logo_size := Vector2(logo.get_width(), logo.get_height()) * (w * 0.28 / logo.get_width())
		draw_texture_rect(_keep(ImageTexture.create_from_image(logo)), Rect2(Vector2((w - logo_size.x) * 0.5, y - logo_size.y - margin * 0.4), logo_size), false)
		var colors := [Color("#B9C0C6"), Color("#D6DADF")]
		for index in lines.size():
			var line_y := y + line_height * index + label.get_ascent(label_size)
			draw_string(label, Vector2(0, line_y), lines[index], HORIZONTAL_ALIGNMENT_CENTER, w, label_size, colors[index % colors.size()])

	## Blurs [param image] with a Gaussian of standard deviation [param sigma]
	## pixels, as two passes of a one-dimensional kernel. Edges repeat.
	func _gaussian_blur(image: Image, sigma: float) -> Image:
		var radius := int(ceil(sigma * 3.0))
		var kernel := PackedFloat32Array()
		var total := 0.0
		for i in range(-radius, radius + 1):
			var weight := exp(-0.5 * i * i / (sigma * sigma))
			kernel.append(weight)
			total += weight
		for i in kernel.size():
			kernel[i] /= total
		var width := image.get_width()
		var height := image.get_height()
		var data := image.get_data()
		for vertical in [false, true]:
			var out := PackedByteArray()
			out.resize(data.size())
			var count := height if vertical else width
			for y in height:
				for x in width:
					for channel in 4:
						var sum := 0.0
						for k in kernel.size():
							var at := clampi((y if vertical else x) + k - radius, 0, count - 1)
							var index := ((at * width + x) if vertical else (y * width + at)) * 4 + channel
							sum += data[index] * kernel[k]
						out[(y * width + x) * 4 + channel] = int(round(sum))
			data = out
		return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)

	func _font(path: String) -> FontFile:
		var font := FontFile.new()
		font.load_dynamic_font(ProjectSettings.globalize_path(path))
		return _keep(font)

	func _keep(resource: Resource) -> Resource:
		_kept.append(resource)
		return resource
