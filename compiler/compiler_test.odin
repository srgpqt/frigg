package main

import "core:slice"
import "core:strings"
import "core:testing"

// The compiler never frees: tests allocate everything in the temporary
// allocator, which the test runner releases after each test.
parse :: proc(src: string) -> (tmpl: ^Template, error: string) {
	return parse_template("t.frigg", "t", src)
}

compile :: proc(t: ^testing.T, src: string, loc := #caller_location) -> string {
	tmpl, error := parse(src)
	testing.expect_value(t, error, "", loc)
	return generate({tmpl}, "views", "app", "shared:frigg")
}

expect_contains :: proc(t: ^testing.T, source, expected: string, loc := #caller_location) {
	testing.expectf(t, strings.contains(source, expected), "expected the generated code to contain:\n%s\n\ngot:\n%s", expected, source, loc = loc)
}

expect_strings :: proc(t: ^testing.T, got: []string, expected: []string, loc := #caller_location) {
	testing.expectf(t, slice.equal(got, expected), "expected %v, got %v", expected, got, loc = loc)
}

@(test)
parse_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cases := [][2]string {
		{"<div><p>x</div>", "1:10: expected </p> before </div>"},
		{"<div>", "1:1: <div> is never closed, expected </div>"},
		{"<div", "1:1: unterminated <div> tag"},
		{"\n\n  </p>", "3:3: unexpected closing tag </p>"},
		{"<a b=\"x>", "1:6: unterminated value of attribute 'b'"},
		{"<p {}>", "1:4: empty {} in <p>"},
		{"<p a={}>", "1:4: empty value of attribute 'a'"},
		{"<p :if=\"x\"></p>", "1:4: :if needs a value in braces, e.g. :if={...}"},
		{"<.card data-x=\"1\" />", "1:8: 'data-x' is not a valid argument name for component <.card>"},
		{"<.card {attrs} />", "1:8: attributes cannot be spread on component <.card>"},
		{"<script>x", "1:1: <script> is never closed"},
		{"<!-- x", "1:1: unterminated HTML comment"},
		{"{}", "1:1: empty {}, write \\{ for a literal brace"},
		{"{ unclosed", "1:1: unterminated '{', write \\{ for a literal brace"},
		{"{# unclosed", "1:1: unterminated comment, expected '#}'"},
		{"{if x}a", "1:1: {if} is never closed, expected {/if}"},
		{"{if}a{/if}", "1:1: {if} needs a condition"},
		{"{if a}{else}{else}{/if}", "1:13: {else} must be the last branch of an {if}"},
		{"{if a}{else unless b}{/if}", "1:7: expected {else} or {else if condition}"},
		{"{if a}<p>{/if}</p>", "1:10: expected </p> before {/if}"},
		{"{else}", "1:1: {else} without a matching {if}"},
		{"{/if}", "1:1: {/if} without a matching {if}"},
		{"{/for}", "1:1: {/for} without a matching {for}"},
		{"{for}x{/for}", "1:1: {for} needs a loop header, e.g. {for item in items}"},
		{"{for x in xs}a{/if}", "1:15: expected {/for} before {/if}"},
		{"x {# args: a: int #}", "1:3: the 'args:' comment must be at the very start of the template"},
		{"{# args: 1x: int #}", "1:1: cannot find the name of template argument '1x: int'"},
	}
	for c in cases {
		_, error := parse(c[0])
		testing.expectf(t, error == strings.concatenate({"t.frigg:", c[1]}), "%q: expected error %q, got %q", c[0], c[1], error)
	}
}

@(test)
only_the_first_error_is_reported :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	_, error := parse("{}\n<div>\n{/for}")
	testing.expect_value(t, error, "t.frigg:1:1: empty {}, write \\{ for a literal brace")
}

@(test)
args_comment :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tmpl, error := parse("{# args: title: string, users: []User, compact := false #}\nx")
	testing.expect_value(t, error, "")
	testing.expect_value(t, tmpl.args, "title: string, users: []User, compact := false")
	expect_strings(t, tmpl.arg_names[:], {"title", "users", "compact"})

	// Parentheses, several lines, a trailing comma, and commas that do not separate arguments.
	tmpl, error = parse("{# args: (\n  a, b: int,\n  sep := \", \",\n  pair: [2]map[string]int = {},\n  cb: proc(x, y: int) -> int = nil,\n  using opts: Options,\n  #any_int n: int,\n  _: bool,\n) #}")
	testing.expect_value(t, error, "")
	expect_strings(t, tmpl.arg_names[:], {"a", "b", "sep", "pair", "cb", "opts", "n"})
	testing.expect(t, strings.has_prefix(tmpl.args, "a, b: int,") && strings.has_suffix(tmpl.args, "_: bool"), tmpl.args)

	tmpl, error = parse("no comment")
	testing.expect_value(t, error, "")
	testing.expect_value(t, tmpl.args, "")
	testing.expect_value(t, len(tmpl.arg_names), 0)
}

@(test)
comments_and_imports :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tmpl, error := parse("{# args: a: int #}\n{# import   \"core:fmt\" #}\n{# import m \"../models\" #}\n{# just a comment #}\nx")
	testing.expect_value(t, error, "")
	expect_strings(t, tmpl.imports[:], {`import "core:fmt"`, `import m "../models"`})
	testing.expect_value(t, len(tmpl.nodes), 1)
	testing.expect_value(t, tmpl.nodes[0].(Text).text, "x")
}

@(test)
text_nodes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tmpl, error := parse("a < b \\{x} } <!-- {c} --><!DOCTYPE html>{code}tail")
	testing.expect_value(t, error, "")
	testing.expect_value(t, len(tmpl.nodes), 3)
	testing.expect_value(t, tmpl.nodes[0].(Text).text, "a < b {x} } <!-- {c} --><!DOCTYPE html>")
	testing.expect_value(t, tmpl.nodes[1].(Expr).code, "code")
	testing.expect_value(t, tmpl.nodes[2].(Text).text, "tail")
}

@(test)
code_scanning :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	sources := []string {
		`Point{1, 2}.x`,
		`"}" + "\"}"`,
		"`}` + `{`",
		`'}'`,
		`'\''`,
		`f(/* } */ 1)`,
		`if_ready`,
		`format(x)`,
		`elsewhere`,
	}
	for source in sources {
		tmpl, error := parse(strings.concatenate({"{ ", source, " }!"}))
		testing.expect_value(t, error, "")
		if testing.expect_value(t, len(tmpl.nodes), 2) {
			testing.expect_value(t, tmpl.nodes[0].(Expr).code, source)
		}
	}

	tmpl, _ := parse("a\n\n{x}\n{y}")
	testing.expect_value(t, tmpl.nodes[1].(Expr).line, 3)
	testing.expect_value(t, tmpl.nodes[3].(Expr).line, 4)
}

@(test)
element_attributes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tmpl, error := parse(`<a class="x y" title='q"q' data-n=5 hidden @click={go} {rest} empty="">t</a>`)
	testing.expect_value(t, error, "")
	elem := tmpl.nodes[0].(^Element)
	testing.expect_value(t, elem.tag, "a")
	testing.expect_value(t, elem.void, false)
	expected := []Attr {
		{"class", .Static, "x y", 1},
		{"title", .Static, `q"q`, 1},
		{"data-n", .Static, "5", 1},
		{"hidden", .Bare, "", 1},
		{"@click", .Expr, "go", 1},
		{"", .Spread, "rest", 1},
		{"empty", .Static, "", 1},
	}
	if testing.expect_value(t, len(elem.attrs), len(expected)) {
		for attr, i in expected {
			testing.expect_value(t, elem.attrs[i], attr)
		}
	}
	testing.expect_value(t, elem.children[0].(Text).text, "t")
}

@(test)
void_self_closing_and_raw_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tmpl, error := parse("<br><BR/><div/><p></p><script>if (a < b) { x = \"</p>{y}\" }</SCRIPT ><style></style>")
	testing.expect_value(t, error, "")
	if !testing.expect_value(t, len(tmpl.nodes), 6) {
		return
	}
	testing.expect(t, tmpl.nodes[0].(^Element).void)
	testing.expect(t, tmpl.nodes[1].(^Element).void)
	testing.expect(t, !tmpl.nodes[2].(^Element).void)
	testing.expect_value(t, len(tmpl.nodes[2].(^Element).children), 0)
	testing.expect_value(t, len(tmpl.nodes[3].(^Element).children), 0)
	script := tmpl.nodes[4].(^Element)
	testing.expect_value(t, len(script.children), 1)
	testing.expect_value(t, script.children[0].(Text).text, "if (a < b) { x = \"</p>{y}\" }")
	testing.expect_value(t, len(tmpl.nodes[5].(^Element).children), 0)
}

@(test)
blocks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tmpl, error := parse("{if a}A{else if b}B{else}C{/if}{for x in xs}{x}{/for}")
	testing.expect_value(t, error, "")
	branches := tmpl.nodes[0].(^If).branches
	if testing.expect_value(t, len(branches), 3) {
		testing.expect_value(t, branches[0].cond, "a")
		testing.expect_value(t, branches[1].cond, "b")
		testing.expect_value(t, branches[1].is_else, false)
		testing.expect_value(t, branches[2].is_else, true)
		testing.expect_value(t, branches[2].body[0].(Text).text, "C")
	}
	loop := tmpl.nodes[1].(^For)
	testing.expect_value(t, loop.header, "x in xs")
	testing.expect_value(t, loop.body[0].(Expr).code, "x")
}

@(test)
for_and_if_attributes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// Whatever their order, :for is the outer construct.
	for src in ([]string{`<li :if={x.ok} :for={x in xs} id="i">`, `<li :for={x in xs} id="i" :if={x.ok}>`}) {
		tmpl, error := parse(strings.concatenate({src, "</li>"}))
		testing.expect_value(t, error, "")
		loop := tmpl.nodes[0].(^For)
		testing.expect_value(t, loop.header, "x in xs")
		condition := loop.body[0].(^If)
		testing.expect_value(t, condition.branches[0].cond, "x.ok")
		elem := condition.branches[0].body[0].(^Element)
		testing.expect_value(t, len(elem.attrs), 1)
		testing.expect_value(t, elem.attrs[0].name, "id")
	}
}

@(test)
standalone_block_lines_are_removed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tmpl, error := parse("a\n  {if x}  \r\n  b\n\t{else}\n  c\n  {/if}\n{# note #}\nd {# inline #}\ne {if y}f{/if}\n")
	testing.expect_value(t, error, "")
	if !testing.expect_value(t, len(tmpl.nodes), 5) {
		return
	}
	testing.expect_value(t, tmpl.nodes[0].(Text).text, "a\n")
	branches := tmpl.nodes[1].(^If).branches
	testing.expect_value(t, branches[0].body[0].(Text).text, "  b\n")
	testing.expect_value(t, branches[1].body[0].(Text).text, "  c\n")
	// Tags sharing their line with something else leave the line alone.
	testing.expect_value(t, tmpl.nodes[2].(Text).text, "d \ne ")
	testing.expect_value(t, tmpl.nodes[4].(Text).text, "\n")
}

@(test)
header_variables :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	expect_strings(t, header_vars("item in items", true)[:], {"item"})
	expect_strings(t, header_vars("item, i in items", true)[:], {"item", "i"})
	expect_strings(t, header_vars("&item, _ in items", true)[:], {"item"})
	expect_strings(t, header_vars("_, value in m", true)[:], {"value"})
	expect_strings(t, header_vars("i in 0..<10", true)[:], {"i"})
	expect_strings(t, header_vars("c in \"x in y\"", true)[:], {"c"})
	expect_strings(t, header_vars("i := 0; i < n; i += 1", true)[:], {"i"})
	expect_strings(t, header_vars("i < 10", true)[:], {})
	expect_strings(t, header_vars("inner < 10", true)[:], {})
	expect_strings(t, header_vars("value, ok := m[key]; ok", false)[:], {"value", "ok"})
	// `in` is an operator in a condition, not a declaration.
	expect_strings(t, header_vars(".Admin in user.roles", false)[:], {})
	expect_strings(t, header_vars("f(proc() -> bool { x := 1; return x == 1 })", false)[:], {})
}

@(test)
top_level_scanning :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, top_level_index("a, b", ","), 1)
	testing.expect_value(t, top_level_index("f(a, b), c", ","), 7)
	testing.expect_value(t, top_level_index(`",", ','`, ","), 3)
	testing.expect_value(t, top_level_index("[2]int{1, 2}", ","), -1)
	testing.expect_value(t, top_level_index("print in", "in", word = true), 6)
	testing.expect_value(t, top_level_index("inner", "in", word = true), -1)
	expect_strings(t, split_top_level("a, f(b, c), \"d,e\"", ",")[:], {"a", " f(b, c)", " \"d,e\""})
	expect_strings(t, split_top_level("a, ", ",")[:], {"a"})
	expect_strings(t, split_top_level("", ",")[:], {})
}

@(test)
names_and_literals :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, procedure_name("index"), "index")
	testing.expect_value(t, procedure_name("user-card.v2"), "user_card_v2")
	testing.expect_value(t, procedure_name("404"), "_404")
	testing.expect_value(t, procedure_name(""), "_")
	testing.expect_value(t, base_name("/a/b/c"), "c")
	testing.expect_value(t, base_name("c"), "c")
	testing.expect_value(t, quote("a\"b\\c\n\r\t\x01é"), `"a\"b\\c\n\r\t\x01é"`)
	testing.expect(t, is_identifier("_a1") && !is_identifier("1a") && !is_identifier("a-b") && !is_identifier(""))
	testing.expect(t, is_component(".card") && is_component("ui.card") && !is_component("x-card"))
}

@(test)
generated_file_header :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a, _ := parse_template("views/a.frigg", "a", "{# import \"core:fmt\" #}\n{# import \"core:time\" #}\na")
	b, _ := parse_template("views/b.frigg", "b", "{# import \"core:fmt\" #}\nb")
	source := generate({a, b}, "views", "app", "../lib/frigg")
	testing.expect(t, strings.has_prefix(source, "// Code generated by frigg from views/*.frigg. DO NOT EDIT.\npackage app\n\nimport frigg \"../lib/frigg\"\nimport \"core:fmt\"\nimport \"core:time\"\n\n// Generated from views/a.frigg\n"), source)
	testing.expect_value(t, strings.count(source, `import "core:fmt"`), 1)
	expect_contains(t, source, "\n// Generated from views/b.frigg\nb :: proc(allocator := context.temp_allocator) -> frigg.Template {\n")
}

@(test)
generated_signature :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	expect_contains(t, compile(t, "{# args: a: int, b := 2 #}"), "t :: proc(a: int, b := 2, allocator := context.temp_allocator) -> frigg.Template {\n\treturn frigg.Template{\"t\", nil}\n}\n")
	// A template can take over the allocator argument.
	expect_contains(t, compile(t, "{# args: allocator: runtime.Allocator #}"), "t :: proc(allocator: runtime.Allocator) -> frigg.Template {")
}

@(test)
generated_nodes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source := compile(t, "{# args: name: string #}\n<p class='a\"b' hidden id={name} {name}>Hi \"{name}\"<br></p>")
	expect_contains(t, source, "\t_Env0 :: struct {\n\t\tname: type_of(name),\n\t}\n\t_env0 := new_clone(_Env0{name = name}, allocator)\n")
	expect_contains(t, source, `_a2[0] = {"class", frigg.Safe_String("a&quot;b")}`)
	expect_contains(t, source, `_a2[1] = {"hidden", true}`)
	expect_contains(t, source, "_a2[2] = {\"id\", frigg.Code{proc(_p: rawptr) -> frigg.Node { // t.frigg:2\n\t\tusing _e := (^_Env0)(_p)\n\t\treturn frigg.to_node(name)\n\t}, _env0}}")
	expect_contains(t, source, "_a2[3] = {\"\", frigg.Spread{proc(_p: rawptr) -> []frigg.Attribute { // t.frigg:2\n\t\tusing _e := (^_Env0)(_p)\n\t\treturn frigg.to_attributes(name)\n\t}, _env0}}")
	expect_contains(t, source, `append(&_n3, frigg.Safe_String("Hi \""))`)
	expect_contains(t, source, `append(&_n3, frigg.element("br", nil, nil, true, allocator))`)
	expect_contains(t, source, `append(&_n1, frigg.element("p", _a2, _n3[:], false, allocator))`)
}

@(test)
generated_code_without_variables :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source := compile(t, "{now()}")
	testing.expect(t, !strings.contains(source, "_Env"), source)
	expect_contains(t, source, "frigg.Code{proc(_: rawptr) -> frigg.Node { // t.frigg:1\n\t\treturn frigg.to_node(now())\n\t}, nil}")
}

@(test)
generated_multiline_code :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// The closing parenthesis must not end up behind a line comment.
	expect_contains(t, compile(t, "{1 + // one\n2}"), "\t\treturn frigg.to_node(\n\t\t\t1 + // one\n2,\n\t\t)\n")
}

@(test)
generated_scopes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// A scope without code of its own takes no snapshot...
	source := compile(t, "{# args: xs: []int #}\n{for x in xs}<b>static</b>{/for}")
	testing.expect(t, !strings.contains(source, "_Env"), source)

	// ...a loop snapshots its variables along with the outer ones...
	source = compile(t, "{# args: xs: []int #}\n{for x, i in xs}{x}{/for}")
	expect_contains(t, source, "\tfor x, i in xs {\n\t\t_Env1 :: struct {\n\t\t\txs: type_of(xs),\n\t\t\tx: type_of(x),\n\t\t\ti: type_of(i),\n\t\t}\n\t\t_env1 := new_clone(_Env1{xs = xs, x = x, i = i}, allocator)\n")
	testing.expect(t, !strings.contains(source, "_Env0"), source)

	// ...a plain `if` shares the scope around it...
	source = compile(t, "{# args: a: int #}\n{if a > 0}{a}{else}{-a}{/if}")
	testing.expect_value(t, strings.count(source, " :: struct {"), 1)
	testing.expect_value(t, strings.count(source, "}, _env0})"), 2)

	// ...and variables declared by an `if` are visible in its later branches.
	source = compile(t, "{# args: m: map[string]int #}\n{if v, ok := m[\"k\"]; ok}{v}{else}{ok}{/if}")
	expect_contains(t, source, "\tif v, ok := m[\"k\"]; ok {\n\t\t_Env1 :: struct {\n\t\t\tm: type_of(m),\n\t\t\tv: type_of(v),\n\t\t\tok: type_of(ok),\n\t\t}\n")
	expect_contains(t, source, "\t} else {\n\t\t_Env2 :: struct {\n\t\t\tm: type_of(m),\n\t\t\tv: type_of(v),\n\t\t\tok: type_of(ok),\n\t\t}\n")

	// A variable shadowing another is only captured once.
	source = compile(t, "{# args: x: int #}\n{for x in 0..<3}{x}{/for}")
	expect_contains(t, source, "\t\t_Env1 :: struct {\n\t\t\tx: type_of(x),\n\t\t}\n")
}

@(test)
generated_components :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source := compile(t, "{# args: user: User #}\n<.card title=\"T\" wide user={user}><b>{user.name}</b></.card><ui.icon name=\"x\" />")
	expect_contains(t, source, `append(&_n1, frigg.to_node(card(title = "T", wide = true, user = user, children = _n2[:], allocator = allocator)))`)
	expect_contains(t, source, `append(&_n1, frigg.to_node(ui.icon(name = "x", allocator = allocator)))`)
	// Arguments of a component are evaluated right away, they are not deferred code.
	testing.expect_value(t, strings.count(source, "frigg.Code{"), 1)
}

/*
`tests/templates.odin` is compiled into the end-to-end tests of the `tests`
package. It must be what the compiler currently generates.
*/
@(test)
end_to_end_templates_are_up_to_date :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	files := #load_directory("../tests/templates")
	templates: [dynamic]^Template
	for file in files {
		if !strings.has_suffix(file.name, ".frigg") {
			continue
		}
		name := procedure_name(strings.trim_suffix(file.name, ".frigg"))
		tmpl, error := parse_template(file.name, name, string(file.data))
		testing.expect_value(t, error, "")
		append(&templates, tmpl)
	}
	slice.sort_by(templates[:], proc(a, b: ^Template) -> bool { return a.path < b.path })
	testing.expect(t, len(templates) > 0, "no templates found in tests/templates")

	source := generate(templates[:], "templates", "tests", "../frigg")
	testing.expect(
		t,
		source == #load("../tests/templates.odin", string),
		"tests/templates.odin is stale, regenerate it with: ./bin/frigg -r -import:./frigg tests/templates",
	)
}
