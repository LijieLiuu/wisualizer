extends RefCounted
## Lets the notes show images from their ZIP with Godot's own [img] tag:
## [code][img]images/re.svg[/img][/code], with any of [img]'s options, such
## as [code][img width=320]images/flow.png[/img][/code]. Paths are relative to
## the notes file.
##
## [RichTextLabel] loads an [img] path through [ResourceLoader], which looks in
## the resource cache first. So each image becomes a texture that takes over a
## path of its own, and the notes refer to that path instead.
##
## SVGs stay sharp at any scale. Their [code]currentColor[/code] becomes the
## notes' text color, so they read on dark glass, and sizes in [code]ex[/code],
## as MathJax writes them, are converted to pixels.
##
## Formulas are TeX in a [code][math]…[/math][/code] tag, typeset by [MathJax]
## into such an SVG with its baseline on the text's; [code][math=display][/code]
## sets one on a line of its own.

const RASTER := ["png", "jpg", "jpeg", "webp"]
const IMAGE_TAG := "\\[img([^\\]]*)\\]([^\\[]*)\\[/img\\]"
const MATH_TAG := "\\[math(=display)?\\]([\\s\\S]*?)\\[/math\\]"

## The textures the notes show. The resource cache only holds them while
## someone else does, so keep this as long as the notes are shown.
var textures: Array[Texture2D] = []


## True for files the notes may show as images.
static func is_image(file: String) -> bool:
	return file.get_extension().to_lower() in RASTER or file.get_extension().to_lower() == "svg"


## Returns [param text] with each [img] path from the ZIP replaced by the path
## of a texture holding that image, and each [math] formula by an [img] of its
## SVG. [param read] gives a file's bytes by its path in the ZIP, or none;
## [param notes_path] is where the notes are in the ZIP; [param scope] keeps
## one document's paths apart from another's.
func embed(text: String, read: Callable, notes_path: String, scope: String, text_color: Color, font_size: int) -> String:
	var tag := RegEx.create_from_string(IMAGE_TAG)
	var paths := {}
	var result := ""
	var last := 0
	for found in tag.search_all(text):
		var source := notes_path.get_base_dir().path_join(found.get_string(2).strip_edges()).simplify_path()
		if not paths.has(source):
			paths[source] = _load(read.call(source), source, scope, text_color, font_size)
		result += text.substr(last, found.get_start() - last)
		result += "[img%s]%s[/img]" % [found.get_string(1), paths[source] if not paths[source].is_empty() else found.get_string(2)]
		last = found.get_end()
	return _embed_formulas(result + text.substr(last), scope, text_color, font_size)


## Returns [param text] with each [math] tag replaced by an [img] of the
## formula, or by the formula itself and what's wrong with it if it didn't
## typeset.
func _embed_formulas(text: String, scope: String, text_color: Color, font_size: int) -> String:
	var tag := RegEx.create_from_string(MATH_TAG)
	var images := {}
	var result := ""
	var last := 0
	for found in tag.search_all(text):
		var display := not found.get_string(1).is_empty()
		var tex := found.get_string(2).strip_edges()
		var key := found.get_string(1) + tex
		if not images.has(key):
			images[key] = _typeset(tex, display, scope, text_color, font_size)
		result += text.substr(last, found.get_start() - last) + images[key]
		last = found.get_end()
	return result + text.substr(last)


## Typesets [param tex] into a texture with a path of its own, and returns the
## [img] tag showing it, centered on its own line if [param display].
func _typeset(tex: String, display: bool, scope: String, text_color: Color, font_size: int) -> String:
	var svg: String = MathJax.tex_to_svg(tex, display)
	if svg.is_empty():
		push_warning("The notes' formula %s didn't typeset: %s" % [tex, MathJax.get_error_message()])
		return "[code]%s[/code] [i](%s)[/i]" % [tex.replace("[", "[lb]").replace("]", "[rb]"), MathJax.get_error_message()]
	var texture := DPITexture.create_from_string(_prepare_svg(_center_baseline(svg), text_color, font_size))
	var path := "math://%s/%d" % [scope, textures.size()]
	texture.take_over_path(path)
	textures.append(texture)
	var image := "[img=center,baseline]%s[/img]" % path
	return "[center]%s[/center]" % image if display else image


## Loads the image [param bytes] of [param source] into a texture with a path
## of its own, and returns that path, or an empty string if it isn't an image.
func _load(bytes: PackedByteArray, source: String, scope: String, text_color: Color, font_size: int) -> String:
	if bytes.is_empty() or not is_image(source):
		push_warning("The notes show %s, which isn't an image in the ZIP." % source)
		return ""
	var texture: Texture2D
	var extension := source.get_extension().to_lower()
	if extension == "svg":
		texture = DPITexture.create_from_string(_prepare_svg(bytes.get_string_from_utf8(), text_color, font_size))
	else:
		var image := Image.new()
		var error: Error
		match extension:
			"png":
				error = image.load_png_from_buffer(bytes)
			"webp":
				error = image.load_webp_from_buffer(bytes)
			_:
				error = image.load_jpg_from_buffer(bytes)
		if error != OK:
			push_warning("Couldn't read the image %s." % source)
			return ""
		texture = ImageTexture.create_from_image(image)
	var path := "zip://%s/%s" % [scope, source]
	texture.take_over_path(path)
	textures.append(texture)
	return path


## Gives the SVG the text's color and turns MathJax's ex sizes into pixels,
## taking an ex as half the font size.
static func _prepare_svg(svg: String, text_color: Color, font_size: int) -> String:
	svg = svg.replace("currentColor", "#" + text_color.to_html(false))
	var size := RegEx.create_from_string("(<svg[^>]*?\\b(?:width|height)=\")([0-9.]+)ex\"")
	var found := size.search(svg)
	while found:
		var pixels := found.get_string(2).to_float() * font_size * 0.5
		svg = svg.substr(0, found.get_start()) + "%s%.2f\"" % [found.get_string(1), pixels] + svg.substr(found.get_end())
		found = size.search(svg)
	return svg


## Pads a MathJax SVG above or below so that its baseline, at y = 0 of its
## viewBox, is at its vertical middle, which [code][img=center,baseline][/code]
## then puts on the text's baseline.
static func _center_baseline(svg: String) -> String:
	var box := RegEx.create_from_string("viewBox=\"([-0-9.]+) ([-0-9.]+) ([-0-9.]+) ([-0-9.]+)\"").search(svg)
	var height := RegEx.create_from_string("\\bheight=\"([0-9.]+)ex\"").search(svg)
	if not box or not height:
		return svg
	var ascent := -box.get_string(2).to_float()
	var total := box.get_string(4).to_float()
	var half := maxf(ascent, total - ascent)
	svg = svg.replace(box.get_string(0), "viewBox=\"%s %s %s %s\"" % [box.get_string(1), -half, box.get_string(3), 2 * half])
	return svg.replace(height.get_string(0), "height=\"%sex\"" % (height.get_string(1).to_float() * 2 * half / total))
