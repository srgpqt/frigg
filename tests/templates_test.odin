package tests

import "core:testing"

import frigg "../frigg"
import nested "templates"

render :: proc(node: frigg.Node) -> string {
	return frigg.to_string(node, context.temp_allocator)
}

@(test)
static_text_is_verbatim :: proc(t: ^testing.T) {
	testing.expect_value(t, render(static()), "<!DOCTYPE html>\n<!-- kept {verbatim} -->\n<p>a < b &amp; {literal} }</p>\n")
}

@(test)
template_without_args :: proc(t: ^testing.T) {
	testing.expect_value(t, render(_0_plain()), "no args: 2")
}

@(test)
values_are_escaped_unless_safe :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		render(values("<x>", 7, "<b>ok</b>", true, {"a", "b"})),
		"<p>&lt;x&gt;|7|<b>ok</b>|true|[&quot;a&quot;, &quot;b&quot;]|15|}{|}</p>\n",
	)
}

@(test)
attributes_all_kinds :: proc(t: ^testing.T) {
	data := make(map[string]string, context.temp_allocator)
	data["z"] = "<"
	data["a"] = "1"
	testing.expect_value(
		t,
		render(attributes("main", true, {{"role", string(`b"q`)}, {"open", true}}, data)),
		`<a class="btn" title="say &quot;hi&quot;" data-x="plain" hidden id="main" checked raw="a&b" role="b&quot;q" open a="1" z="&lt;">x</a>` + "\n",
	)
}

@(test)
attributes_false_and_nil_are_omitted :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		render(attributes("x", false)),
		`<a class="btn" title="say &quot;hi&quot;" data-x="plain" hidden id="x" disabled raw="a&b">x</a>` + "\n",
	)
}

@(test)
control_flow :: proc(t: ^testing.T) {
	lookup := make(map[string]int, context.temp_allocator)
	lookup["key"] = 5
	testing.expect_value(
		t,
		render(control(3, {"a", "skip", "b"}, lookup)),
		"big\n<ul>\n  <li>0: a</li>\n  <li>1: skip</li>\n  <li>2: b</li>\n</ul>\n" +
		"<i title=\"a\">a</i><i title=\"b\">b</i>\n[0][1]\n(0,0)(0,1)(1,0)(1,1)\nfound 5\n",
	)
	testing.expect_value(
		t,
		render(control(2, {}, nil)),
		"medium\n<ul>\n</ul>\n\n[0][1]\n(0,0)(0,1)(1,0)(1,1)\nnot found: false\n",
	)
	testing.expect_value(
		t,
		render(control(0, {"z"}, nil)),
		"small\n<ul>\n  <li>0: z</li>\n</ul>\n<i title=\"z\">z</i>\n[0][1]\n(0,0)(0,1)(1,0)(1,1)\nnot found: false\n",
	)
}

@(test)
components :: proc(t: ^testing.T) {
	testing.expect_value(t, render(card("T")), "<section class=\"narrow\"><h2>T</h2></section>\n")
	testing.expect_value(
		t,
		render(page({"x", "y"})),
		"<section class=\"wide\"><h2>Static</h2><p>2 names</p></section>\n\n" +
		"<section class=\"narrow\"><h2>x</h2></section>\n<section class=\"narrow\"><h2>y</h2></section>\n\n" +
		"<section class=\"narrow\"><h2>Direct</h2></section>\n\n",
	)
}

@(test)
void_and_raw_text_elements :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		render(elements()),
		"<br><br><img src=\"a.png\"><div></div><x-widget></x-widget>\n" +
		"<style>\n  a > b { color: red; }\n</style>\n" +
		"<SCRIPT>if (a < b) { f(\"</div>{x}\") }</SCRIPT>\n",
	)
}

@(test)
double_brace_code :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		render(raw_code("<Bob>", "red", `{"debug": true}`)),
		"<p title=\"&lt;Bob&gt;\" lang>&lt;Bob&gt; = &lt;Bob&gt;</p>\n" +
		"<style>\n  p { color: red; }\n</style>\n" +
		"<script>\n  const config = {\"debug\": true};\n  const name = \"&lt;Bob&gt;\";\n  if (config) { console.log(\"{{literal}}\") }\n" +
		"  console.log(\"no modules\");\n</script>\n\n",
	)
	testing.expect_value(
		t,
		render(raw_code("x", "blue", "{}", {"nav", "grid"})),
		"<p title=\"x\" lang>x = x</p>\n" +
		"<style>\n  p { color: blue; }\n  .nav { display: block; }\n  .grid { display: block; }\n</style>\n" +
		"<script>\n  const config = {};\n  const name = \"x\";\n  if (config) { console.log(\"{{literal}}\") }\n" +
		"  load([\"nav\", \"grid\"]);\n</script>\n<ul><li>nav</li><li>grid</li></ul>\n",
	)
}

@(test)
code_runs_on_serialization_only :: proc(t: ^testing.T) {
	counter := 0
	tree := deferred(&counter)
	testing.expect_value(t, counter, 0)
	testing.expect_value(t, render(tree), "<p>1</p><p data-n=\"2\"></p>\n")
	// Every serialization runs the code again.
	testing.expect_value(t, render(tree), "<p>3</p><p data-n=\"4\"></p>\n")
	testing.expect_value(t, counter, 4)
}

@(test)
loop_variables_are_snapshotted :: proc(t: ^testing.T) {
	items := []string{"a", "b"}
	tree := control(0, items, nil)
	// Arguments are captured by value: slices still share their backing data...
	items[0] = "changed"
	// ...but loop variables were copied for each iteration.
	testing.expect(t, render(tree) == "small\n<ul>\n  <li>0: a</li>\n  <li>1: b</li>\n</ul>\n<i title=\"a\">a</i><i title=\"b\">b</i>\n[0][1]\n(0,0)(0,1)(1,0)(1,1)\nnot found: false\n")
}

@(test)
tree_structure :: proc(t: ^testing.T) {
	tree := card("T")
	testing.expect_value(t, tree.name, "card")
	testing.expect_value(t, len(tree.children), 2)

	section, is_element := tree.children[0].(^frigg.Element)
	if !testing.expect(t, is_element) {
		return
	}
	testing.expect_value(t, section.tag, "section")
	testing.expect_value(t, section.void, false)
	testing.expect_value(t, len(section.attributes), 1)
	testing.expect_value(t, section.attributes[0].name, "class")
	_, is_code := section.attributes[0].value.(frigg.Code)
	testing.expect(t, is_code)

	testing.expect_value(t, len(section.children), 2)
	h2 := section.children[0].(^frigg.Element) or_else nil
	if !testing.expect(t, h2 != nil && h2.tag == "h2") {
		return
	}
	code, is_child_code := h2.children[0].(frigg.Code)
	if !testing.expect(t, is_child_code) {
		return
	}
	testing.expect_value(t, frigg.eval(code).(string) or_else "", "T")

	newline, is_safe := tree.children[1].(frigg.Safe_String)
	testing.expect(t, is_safe && newline == "\n")
}

@(test)
recursive_subdirectory :: proc(t: ^testing.T) {
	testing.expect_value(t, render(nested.leaf("<leaf>")), "<b>&lt;leaf&gt;</b>\n")
}
