/*
Package frigg is the runtime library for templates compiled by the `frigg`
template compiler.

Every `*.frigg` template is compiled to an Odin procedure returning a
`Template`: a tree of `Node`s that can be inspected, walked with `walk`, or
serialized with `write`, `write_to_builder` and `to_string`.

	page := templates.index("Hello", items)
	html := frigg.to_string(page)

Serialization rules:
- `Safe_String` nodes (all the static text of a template) are written verbatim.
- `Code` nodes are called when the tree is serialized or walked, and whatever
  they return is serialized in their place.
- Every other value is HTML escaped.
*/
package frigg

import "core:fmt"
import "core:io"
import "core:strings"

// Text that is trusted to be valid HTML and is written verbatim, without escaping.
Safe_String :: distinct string

// Signature of the procedures generated for `{code}` in a template.
// `env` points to a snapshot of the template variables visible to the code.
Code_Proc :: #type proc(env: rawptr) -> Node

// A deferred piece of template code. It is only run when the tree is
// serialized or walked, see `eval`.
Code :: struct {
	call: Code_Proc,
	env:  rawptr,
}

// Signature of the procedures generated for `<div {attributes}>` in a template.
Spread_Proc :: #type proc(env: rawptr) -> []Attribute

// A deferred list of attributes, expanded in place when the element is serialized.
Spread :: struct {
	call: Spread_Proc,
	env:  rawptr,
}

/*
The value of an HTML attribute.

- `Safe_String`: written verbatim between double quotes.
- `string`:      HTML escaped.
- `bool`:        `true` writes the bare attribute name, `false` omits the attribute.
- `Code`:        called on serialization; a `nil` or `false` result omits the attribute.
- `Spread`:      called on serialization and replaced by the attributes it returns.
- `nil`:         the attribute is omitted.
*/
Attribute_Value :: union {
	Safe_String,
	string,
	bool,
	Code,
	Spread,
}

Attribute :: struct {
	name:  string, // empty for a `Spread`
	value: Attribute_Value,
}

Element :: struct {
	tag:        string,
	attributes: []Attribute,
	children:   []Node,
	void:       bool, // void elements (`<br>`, `<img>`...) have no children and no closing tag
}

// The tree returned by a compiled template.
Template :: struct {
	name:     string,
	children: []Node,
}

/*
A node of a template tree.

- `Safe_String`: static text, written verbatim.
- `string`:      dynamic text, HTML escaped.
- `bool`:        written as `true` or `false`.
- `^Element`:    an HTML element with its attributes and children.
- `Code`:        deferred code, replaced by its result.
- `Template`:    a nested template.
- `[]Node`:      a list of nodes.
- `nil`:         nothing.
*/
Node :: union {
	Safe_String,
	string,
	bool,
	^Element,
	Code,
	Template,
	[]Node,
}

// Allocates an `Element`. Used by generated code.
element :: proc(
	tag: string,
	attributes: []Attribute,
	children: []Node,
	void := false,
	allocator := context.temp_allocator,
) -> ^Element {
	e := new(Element, allocator)
	e^ = {tag, attributes, children, void}
	return e
}

/*
Converts any value to a `Node`.

Node variants are passed through unchanged, so `Safe_String`s, elements and
nested templates keep their meaning. Any other value is formatted with
`core:fmt` into a `string` node, which is HTML escaped on serialization.
Formatting allocates with `context.temp_allocator`.
*/
to_node :: proc(value: $T) -> Node {
	when T == Node || T == Safe_String || T == string || T == bool || T == ^Element || T == Code || T == Template || T == []Node {
		return value
	} else when T == [dynamic]Node {
		return value[:]
	} else when T == Element {
		return new_clone(value, context.temp_allocator)
	} else when T == cstring {
		return string(value)
	} else {
		return format(value)
	}
}

/*
Converts a value to a list of attributes, for `<div {value}>`.

Accepts `[]Attribute`, `[dynamic]Attribute`, a single `Attribute`, and
`map[string]string` (values are HTML escaped, attributes are sorted by name).
Conversions allocate with `context.temp_allocator`.
*/
to_attributes :: proc(value: $T) -> []Attribute {
	when T == []Attribute {
		return value
	} else when T == [dynamic]Attribute {
		return value[:]
	} else when T == Attribute {
		attributes := make([]Attribute, 1, context.temp_allocator)
		attributes[0] = value
		return attributes
	} else when T == map[string]string {
		attributes := make([]Attribute, len(value), context.temp_allocator)
		count := 0
		for name, v in value {
			// Insertion sort: map iteration order is not stable.
			i := count
			for ; i > 0 && attributes[i - 1].name > name; i -= 1 {
				attributes[i] = attributes[i - 1]
			}
			attributes[i] = {name, v}
			count += 1
		}
		return attributes
	} else {
		#panic("frigg: attributes can only be spread from []Attribute, [dynamic]Attribute, Attribute or map[string]string")
	}
}

// Runs a `Code` node and returns its result.
eval :: proc(code: Code) -> Node {
	if code.call == nil {
		return nil
	}
	return code.call(code.env)
}

// Writes the HTML serialization of `node` to `w`.
write :: proc(w: io.Writer, node: Node) -> io.Error {
	switch n in node {
	case Safe_String:
		write_raw(w, string(n)) or_return
	case string:
		write_escaped(w, n) or_return
	case bool:
		write_raw(w, "true" if n else "false") or_return
	case ^Element:
		write_element(w, n) or_return
	case Code:
		write(w, eval(n)) or_return
	case Template:
		for child in n.children {
			write(w, child) or_return
		}
	case []Node:
		for child in n {
			write(w, child) or_return
		}
	}
	return nil
}

// Appends the HTML serialization of `node` to a string builder.
write_to_builder :: proc(sb: ^strings.Builder, node: Node) {
	write(strings.to_writer(sb), node)
}

// Serializes `node` to a newly allocated HTML string.
to_string :: proc(node: Node, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	write_to_builder(&sb, node)
	return strings.to_string(sb)
}

// Writes `s` to `w`, escaping the characters `&`, `<`, `>`, `"` and `'`.
write_escaped :: proc(w: io.Writer, s: string) -> io.Error {
	start := 0
	for i in 0 ..< len(s) {
		entity: string
		switch s[i] {
		case '&':  entity = "&amp;"
		case '<':  entity = "&lt;"
		case '>':  entity = "&gt;"
		case '"':  entity = "&quot;"
		case '\'': entity = "&#39;"
		case:      continue
		}
		write_raw(w, s[start:i]) or_return
		write_raw(w, entity) or_return
		start = i + 1
	}
	return write_raw(w, s[start:])
}

// Returns an HTML escaped copy of `s`.
escape :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	write_escaped(strings.to_writer(&sb), s)
	return strings.to_string(sb)
}

/*
Called by `walk` for every node of a tree, parents first. `depth` is the
nesting level of the node. Return `false` to skip the children of the node
(or the result of a `Code` node).
*/
Visitor :: #type proc(node: Node, depth: int, user_data: rawptr) -> (descend: bool)

/*
Walks a tree depth first, calling `visit` on every node.

`Code` nodes are visited first, then run, and their result is walked as their
only child.
*/
walk :: proc(node: Node, visit: Visitor, user_data: rawptr = nil, depth := 0) {
	if node == nil || !visit(node, depth, user_data) {
		return
	}
	#partial switch n in node {
	case ^Element:
		if n != nil {
			for child in n.children {
				walk(child, visit, user_data, depth + 1)
			}
		}
	case Code:
		walk(eval(n), visit, user_data, depth + 1)
	case Template:
		for child in n.children {
			walk(child, visit, user_data, depth + 1)
		}
	case []Node:
		for child in n {
			walk(child, visit, user_data, depth + 1)
		}
	}
}

@(private)
format :: proc(value: any) -> string {
	return fmt.tprint(value)
}

@(private)
write_raw :: proc(w: io.Writer, s: string) -> io.Error {
	if len(s) == 0 {
		return nil
	}
	_, err := io.write_string(w, s)
	return err
}

@(private)
write_element :: proc(w: io.Writer, e: ^Element) -> io.Error {
	if e == nil {
		return nil
	}
	write_raw(w, "<") or_return
	write_raw(w, e.tag) or_return
	for attribute in e.attributes {
		write_attribute(w, attribute.name, attribute.value) or_return
	}
	write_raw(w, ">") or_return
	if e.void {
		return nil
	}
	for child in e.children {
		write(w, child) or_return
	}
	write_raw(w, "</") or_return
	write_raw(w, e.tag) or_return
	return write_raw(w, ">")
}

@(private)
write_attribute :: proc(w: io.Writer, name: string, value: Attribute_Value) -> io.Error {
	switch v in value {
	case Safe_String:
		write_raw(w, " ") or_return
		write_raw(w, name) or_return
		write_raw(w, "=\"") or_return
		write_raw(w, string(v)) or_return
		write_raw(w, "\"") or_return
	case string:
		write_raw(w, " ") or_return
		write_raw(w, name) or_return
		write_raw(w, "=\"") or_return
		write_escaped(w, v) or_return
		write_raw(w, "\"") or_return
	case bool:
		if v {
			write_raw(w, " ") or_return
			write_raw(w, name) or_return
		}
	case Code:
		write_attribute_node(w, name, eval(v)) or_return
	case Spread:
		if v.call != nil {
			for attribute in v.call(v.env) {
				write_attribute(w, attribute.name, attribute.value) or_return
			}
		}
	}
	return nil
}

// Writes an attribute whose value is the result of a `Code` node.
@(private)
write_attribute_node :: proc(w: io.Writer, name: string, node: Node) -> io.Error {
	switch n in node {
	case Safe_String:
		return write_attribute(w, name, n)
	case string:
		return write_attribute(w, name, n)
	case bool:
		return write_attribute(w, name, n)
	case Code:
		return write_attribute_node(w, name, eval(n))
	case ^Element, Template, []Node:
		// Markup inside an attribute value is serialized, then escaped.
		return write_attribute(w, name, to_string(node, context.temp_allocator))
	}
	return nil
}
