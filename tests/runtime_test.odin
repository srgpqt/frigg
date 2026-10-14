package tests

import "core:io"
import "core:strings"
import "core:testing"

import frigg "../frigg"

@(test)
escape :: proc(t: ^testing.T) {
	testing.expect_value(t, frigg.escape(`<a href="x">Tom & 'Jerry'</a>`, context.temp_allocator), "&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;")
	testing.expect_value(t, frigg.escape("", context.temp_allocator), "")
	testing.expect_value(t, frigg.escape("plain ünïcode", context.temp_allocator), "plain ünïcode")
}

@(test)
node_kinds :: proc(t: ^testing.T) {
	testing.expect_value(t, render(nil), "")
	testing.expect_value(t, render(frigg.Safe_String("<b>")), "<b>")
	testing.expect_value(t, render(string("<b>")), "&lt;b&gt;")
	testing.expect_value(t, render(true), "true")
	testing.expect_value(t, render(false), "false")
	testing.expect_value(t, render((^frigg.Element)(nil)), "")
	testing.expect_value(t, render(frigg.Code{}), "")
	testing.expect_value(t, render([]frigg.Node{string("a"), nil, frigg.Safe_String("&"), true}), "a&true")
	testing.expect_value(t, render(frigg.Template{"t", {string("<"), frigg.Safe_String("<")}}), "&lt;<")
}

@(test)
elements_by_hand :: proc(t: ^testing.T) {
	br := frigg.element("br", {{"class", frigg.Safe_String("x")}}, {string("ignored")}, void = true)
	testing.expect_value(t, render(br), `<br class="x">`)

	code := frigg.Code{proc(env: rawptr) -> frigg.Node { return (^string)(env)^ }, nil}
	text := "<dynamic>"
	code.env = &text
	nil_code := frigg.Code{proc(_: rawptr) -> frigg.Node { return nil }, nil}
	markup := frigg.Code{proc(_: rawptr) -> frigg.Node { return frigg.element("b", nil, nil) }, nil}
	spread := frigg.Spread{proc(_: rawptr) -> []frigg.Attribute {
		return frigg.to_attributes(frigg.Attribute{"spread", string("s")})
	}, nil}
	div := frigg.element(
		"div",
		{
			{"safe", frigg.Safe_String("a&b")},
			{"text", string("a&b")},
			{"on", true},
			{"off", false},
			{"none", nil},
			{"code", code},
			{"nil-code", nil_code},
			{"markup", markup},
			{"", spread},
			{"", frigg.Spread{}},
		},
		{code, br},
	)
	testing.expect_value(
		t,
		render(div),
		`<div safe="a&b" text="a&amp;b" on code="&lt;dynamic&gt;" markup="&lt;b&gt;&lt;/b&gt;" spread="s">&lt;dynamic&gt;<br class="x"></div>`,
	)
}

@(test)
to_node_conversions :: proc(t: ^testing.T) {
	testing.expect_value(t, frigg.to_node("s").(string) or_else "", "s")
	testing.expect_value(t, frigg.to_node(frigg.Safe_String("s")).(frigg.Safe_String) or_else "", "s")
	testing.expect_value(t, frigg.to_node(true).(bool) or_else false, true)
	testing.expect_value(t, frigg.to_node(cstring("c")).(string) or_else "", "c")
	testing.expect_value(t, frigg.to_node(42).(string) or_else "", "42")
	testing.expect_value(t, frigg.to_node(1.5).(string) or_else "", "1.5")
	testing.expect_value(t, frigg.to_node('x').(string) or_else "", "x")
	testing.expect(t, frigg.to_node(frigg.Node(nil)) == nil)

	Color :: enum {
		Red,
		Green,
	}
	testing.expect_value(t, frigg.to_node(Color.Green).(string) or_else "", "Green")

	list := make([dynamic]frigg.Node, context.temp_allocator)
	append(&list, frigg.Node(string("a")), frigg.Node(string("b")))
	testing.expect_value(t, len(frigg.to_node(list).([]frigg.Node) or_else nil), 2)

	element := frigg.to_node(frigg.Element{tag = "hr", void = true}).(^frigg.Element) or_else nil
	testing.expect(t, element != nil && element.tag == "hr")
	testing.expect_value(t, frigg.to_node(frigg.Template{name = "t"}).(frigg.Template).name, "t")
}

@(test)
to_attributes_conversions :: proc(t: ^testing.T) {
	list := []frigg.Attribute{{"a", true}}
	testing.expect_value(t, len(frigg.to_attributes(list)), 1)

	dynamic_list := make([dynamic]frigg.Attribute, context.temp_allocator)
	append(&dynamic_list, frigg.Attribute{"a", true}, frigg.Attribute{"b", true})
	testing.expect_value(t, len(frigg.to_attributes(dynamic_list)), 2)

	// Maps are sorted by name, for a stable output.
	names := make(map[string]string, context.temp_allocator)
	for name in ([]string{"m", "z", "a", "q", "b"}) {
		names[name] = name
	}
	sorted := frigg.to_attributes(names)
	if !testing.expect_value(t, len(sorted), 5) {
		return
	}
	for name, i in ([]string{"a", "b", "m", "q", "z"}) {
		testing.expect_value(t, sorted[i].name, name)
		testing.expect_value(t, sorted[i].value.(string) or_else "", name)
	}
}

@(test)
write_to_builder_appends :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "before ")
	frigg.write_to_builder(&sb, string("<x>"))
	testing.expect_value(t, strings.to_string(sb), "before &lt;x&gt;")
}

@(test)
write_reports_errors :: proc(t: ^testing.T) {
	broken := io.Writer {
		procedure = proc(_: rawptr, mode: io.Stream_Mode, _: []byte, _: i64, _: io.Seek_From) -> (i64, io.Error) {
			return 0, .Invalid_Write if mode == .Write else .Unsupported
		},
	}
	tree := frigg.element("p", {{"a", true}}, {string("text")})
	testing.expect_value(t, frigg.write(broken, tree), io.Error.Invalid_Write)
	testing.expect_value(t, frigg.write(broken, nil), io.Error.None)
}

Visit :: struct {
	kind:  string,
	depth: int,
}

Visits :: struct {
	visits: [dynamic]Visit,
	skip:   string, // tag of the elements whose children are skipped
}

record_visit :: proc(node: frigg.Node, depth: int, user_data: rawptr) -> bool {
	state := (^Visits)(user_data)
	kind: string
	switch n in node {
	case frigg.Safe_String: kind = "safe"
	case string:            kind = "string"
	case bool:              kind = "bool"
	case ^frigg.Element:    kind = n.tag
	case frigg.Code:        kind = "code"
	case frigg.Template:    kind = "template"
	case []frigg.Node:      kind = "list"
	}
	append(&state.visits, Visit{kind, depth})
	element, is_element := node.(^frigg.Element)
	return !is_element || element.tag != state.skip
}

@(test)
walk_visits_parents_first :: proc(t: ^testing.T) {
	code := frigg.Code{proc(_: rawptr) -> frigg.Node { return string("result") }, nil}
	tree := frigg.Template{"t", {
		frigg.Safe_String("text"),
		nil,
		frigg.element("ul", nil, {frigg.element("li", nil, {code}), frigg.element("li", nil, nil)}),
		[]frigg.Node{true},
	}}

	state := Visits{visits = make([dynamic]Visit, context.temp_allocator)}
	frigg.walk(tree, record_visit, &state)
	expected := []Visit {
		{"template", 0},
		{"safe", 1},
		{"ul", 1},
		{"li", 2},
		{"code", 3},
		{"string", 4},
		{"li", 2},
		{"list", 1},
		{"bool", 2},
	}
	if !testing.expect_value(t, len(state.visits), len(expected)) {
		return
	}
	for visit, i in expected {
		testing.expect_value(t, state.visits[i], visit)
	}

	// Returning false from the visitor skips the children.
	clear(&state.visits)
	state.skip = "ul"
	frigg.walk(tree, record_visit, &state)
	testing.expect_value(t, len(state.visits), 5)
}

// Slices may be literals on the stack of the code returning them: they are copied.
@(test)
returned_slices_are_copied :: proc(t: ^testing.T) {
	attributes := []frigg.Attribute{{"a", true}}
	copied := frigg.to_attributes(attributes)
	testing.expect(t, raw_data(copied) != raw_data(attributes))
	testing.expect_value(t, len(copied), 1)
	testing.expect_value(t, copied[0].name, "a")

	nodes := []frigg.Node{string("x")}
	for node in ([]frigg.Node{frigg.to_node(nodes), frigg.to_node(frigg.Node(nodes))}) {
		list := node.([]frigg.Node) or_else nil
		testing.expect(t, list != nil && raw_data(list) != raw_data(nodes))
		testing.expect_value(t, render(node), "x")
	}

	code := frigg.Code{proc(_: rawptr) -> frigg.Node {
		return frigg.to_node([]frigg.Node{string("from"), frigg.Safe_String(" the stack")})
	}, nil}
	spread := frigg.Spread{proc(_: rawptr) -> []frigg.Attribute {
		return frigg.to_attributes([]frigg.Attribute{{"data-a", string("1")}, {"data-b", true}})
	}, nil}
	testing.expect_value(t, render(frigg.element("p", {{"", spread}}, {code})), `<p data-a="1" data-b>from the stack</p>`)
}
