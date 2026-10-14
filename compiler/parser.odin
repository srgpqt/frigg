package main

import "core:fmt"
import "core:strings"

// Static text, emitted as a `frigg.Safe_String`.
Text :: struct {
	text: string,
}

// `{code}`, emitted as a `frigg.Code`.
Expr :: struct {
	code: string,
	line: int,
}

Attr_Kind :: enum {
	Static, // name="value"
	Bare,   // name
	Expr,   // name={code}
	Spread, // {code}
}

Attr :: struct {
	name:  string,
	kind:  Attr_Kind,
	value: string,
	line:  int,
}

Element :: struct {
	tag:      string,
	attrs:    [dynamic]Attr,
	children: [dynamic]Node,
	void:     bool,
	line:     int,
}

Branch :: struct {
	cond:    string,
	is_else: bool,
	body:    [dynamic]Node,
}

// `{if cond}...{else if cond}...{else}...{/if}` or `:if={cond}`
If :: struct {
	branches: [dynamic]Branch,
}

// `{for header}...{/for}` or `:for={header}`
For :: struct {
	header: string,
	body:   [dynamic]Node,
}

Node :: union {
	Text,
	Expr,
	^Element,
	^If,
	^For,
}

Template :: struct {
	path:      string,
	name:      string,   // name of the generated procedure
	args:      string,   // parameter list, verbatim from the `{# args: ... #}` comment
	arg_names: [dynamic]string,
	imports:   [dynamic]string,
	nodes:     [dynamic]Node,
}

Parser :: struct {
	tmpl:  ^Template,
	src:   string,
	pos:   int,
	error: string, // first error encountered
	// Set while parsing the content of a raw text element, which ends at `raw_end`.
	raw:     bool,
	raw_end: int,
}

Terminator_Kind :: enum {
	EOF,
	Close_Tag, // </tag>
	Else,      // {else} or {else if cond}
	End_If,    // {/if}
	End_For,   // {/for}
}

// What stopped `parse_nodes`.
Terminator :: struct {
	kind: Terminator_Kind,
	text: string, // tag name or `else if` condition
	pos:  int,
}

VOID_ELEMENTS :: []string{"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}

// Elements whose content is raw text: no tags, and only `{{code}}` is code.
RAW_TEXT_ELEMENTS :: []string{"script", "style"}

parse_template :: proc(path, name, src: string) -> (tmpl: ^Template, error: string) {
	tmpl = new(Template)
	tmpl.path = path
	tmpl.name = name
	p := Parser{tmpl = tmpl, src = src}
	nodes, term := parse_nodes(&p)
	tmpl.nodes = nodes
	expect_end(&p, term)
	return tmpl, p.error
}

// Reports a terminator found where the content should simply end.
expect_end :: proc(p: ^Parser, term: Terminator) {
	switch term.kind {
	case .EOF:
	case .Close_Tag: fail(p, term.pos, "unexpected closing tag </%s>", term.text)
	case .Else:      fail(p, term.pos, "{{else}} without a matching {{if}}")
	case .End_If:    fail(p, term.pos, "{{/if}} without a matching {{if}}")
	case .End_For:   fail(p, term.pos, "{{/for}} without a matching {{for}}")
	}
}

// Records the first error and moves to the end of the source so that parsing stops.
fail :: proc(p: ^Parser, pos: int, format: string, args: ..any) {
	if p.error == "" {
		line, column := 1, 1
		for i in 0 ..< min(pos, len(p.src)) {
			if p.src[i] == '\n' {
				line += 1
				column = 1
			} else {
				column += 1
			}
		}
		p.error = fmt.aprintf("%s:%d:%d: %s", p.tmpl.path, line, column, fmt.aprintf(format, ..args))
	}
	p.pos = len(p.src)
}

line_at :: proc(p: ^Parser, pos: int) -> int {
	return 1 + strings.count(p.src[:min(pos, len(p.src))], "\n")
}

parse_nodes :: proc(p: ^Parser) -> (nodes: [dynamic]Node, term: Terminator) {
	text: strings.Builder
	flush :: proc(nodes: ^[dynamic]Node, text: ^strings.Builder) {
		if strings.builder_len(text^) > 0 {
			append(nodes, Text{strings.clone(strings.to_string(text^))})
			strings.builder_reset(text)
		}
	}

	// The content of a raw text element is text, except for `{{...}}`.
	limit := p.raw_end if p.raw else len(p.src)
	for p.pos < limit {
		start := p.pos
		rest := p.src[p.pos:limit]
		switch {
		case p.raw && strings.has_prefix(rest, "\\{{"):
			strings.write_string(&text, "{{")
			p.pos += 3

		case p.raw && !strings.has_prefix(rest, "{{"):
			strings.write_byte(&text, rest[0])
			p.pos += 1

		case strings.has_prefix(rest, "\\{"):
			strings.write_byte(&text, '{')
			p.pos += 2

		case strings.has_prefix(rest, "{#"):
			end := strings.index(rest, "#}")
			if end < 0 {
				fail(p, start, "unterminated comment, expected '#}}'")
				break
			}
			p.pos += end + 2
			parse_comment(p, strings.trim_space(rest[2:end]), start)
			trim_standalone(p, &text, start)

		case rest[0] == '{':
			code, double := scan_code(p)
			code = strings.trim_space(code)
			switch {
			case p.pos > limit:
				fail(p, start, "'{{{{' is not closed before the end of the element")
			case code == "" && double:
				fail(p, start, "empty {{{{}}}}")
			case code == "":
				fail(p, start, "empty {{}}, write \\{{ for a literal brace")
			case code == "/if" || code == "/for":
				trim_standalone(p, &text, start)
				flush(&nodes, &text)
				return nodes, {.End_If if code == "/if" else .End_For, "", start}
			case has_keyword(code, "else"):
				cond := strings.trim_space(code[len("else"):])
				if cond != "" {
					if !has_keyword(cond, "if") || strings.trim_space(cond[len("if"):]) == "" {
						fail(p, start, "expected {{else}} or {{else if condition}}")
					}
					cond = strings.trim_space(cond[len("if"):])
				}
				trim_standalone(p, &text, start)
				flush(&nodes, &text)
				return nodes, {.Else, cond, start}
			case has_keyword(code, "if"):
				trim_standalone(p, &text, start)
				flush(&nodes, &text)
				append(&nodes, parse_if(p, strings.trim_space(code[len("if"):]), start))
			case has_keyword(code, "for"):
				trim_standalone(p, &text, start)
				flush(&nodes, &text)
				append(&nodes, parse_for(p, strings.trim_space(code[len("for"):]), start))
			case:
				flush(&nodes, &text)
				append(&nodes, Expr{code, line_at(p, start)})
			}

		case strings.has_prefix(rest, "<!--"):
			end := strings.index(rest, "-->")
			if end < 0 {
				fail(p, start, "unterminated HTML comment")
				break
			}
			strings.write_string(&text, rest[:end + 3])
			p.pos += end + 3

		case strings.has_prefix(rest, "<!"):
			end := strings.index_byte(rest, '>')
			if end < 0 {
				fail(p, start, "unterminated '<!' declaration")
				break
			}
			strings.write_string(&text, rest[:end + 1])
			p.pos += end + 1

		case strings.has_prefix(rest, "</"):
			p.pos += 2
			tag := scan_while(p, is_tag_char)
			skip_space(p)
			if p.pos >= len(p.src) || p.src[p.pos] != '>' {
				fail(p, start, "malformed closing tag")
				break
			}
			p.pos += 1
			flush(&nodes, &text)
			return nodes, {.Close_Tag, tag, start}

		case len(rest) > 1 && rest[0] == '<' && (is_alpha(rest[1]) || rest[1] == '.'):
			flush(&nodes, &text)
			append(&nodes, parse_element(p))

		case:
			strings.write_byte(&text, rest[0])
			p.pos += 1
		}
	}
	flush(&nodes, &text)
	return nodes, {.EOF, "", len(p.src)}
}

// Handles the content of a `{# ... #}` comment: `args:` and `import` are directives.
parse_comment :: proc(p: ^Parser, comment: string, start: int) {
	switch {
	case strings.has_prefix(comment, "args:"):
		if start != 0 {
			fail(p, start, "the 'args:' comment must be at the very start of the template")
			return
		}
		args := strings.trim_space(comment[len("args:"):])
		// The parameter list can be wrapped in parentheses.
		if strings.has_prefix(args, "(") && top_level_index(args[1:], ")") == len(args) - 2 {
			args = strings.trim_space(args[1:len(args) - 1])
		}
		args = strings.trim_space(strings.trim_right(args, ", \t\r\n"))
		p.tmpl.args = args
		for piece in split_top_level(args, ",") {
			arg := strings.trim_space(piece)
			// Skip `using` and directives such as `#any_int`.
			for strings.has_prefix(arg, "#") || has_keyword(arg, "using") {
				space := strings.index_any(arg, " \t")
				if space < 0 {
					break
				}
				arg = strings.trim_space(arg[space:])
			}
			name := arg
			if colon := top_level_index(arg, ":"); colon >= 0 {
				name = strings.trim_space(arg[:colon])
			}
			if !is_identifier(name) {
				fail(p, start, "cannot find the name of template argument '%s'", strings.trim_space(piece))
				return
			}
			if name != "_" {
				append(&p.tmpl.arg_names, name)
			}
		}
	case has_keyword(comment, "import"):
		append(&p.tmpl.imports, strings.join(strings.fields(comment), " "))
	}
}

parse_if :: proc(p: ^Parser, cond: string, start: int) -> ^If {
	node := new(If)
	if cond == "" {
		fail(p, start, "{{if}} needs a condition")
	}
	branch := Branch{cond = cond}
	for {
		term: Terminator
		branch.body, term = parse_nodes(p)
		append(&node.branches, branch)
		#partial switch term.kind {
		case .End_If:
			return node
		case .Else:
			if branch.is_else {
				fail(p, term.pos, "{{else}} must be the last branch of an {{if}}")
				return node
			}
			branch = Branch{cond = term.text, is_else = term.text == ""}
		case:
			unexpected(p, term, start, "{if}", "{/if}")
			return node
		}
	}
}

parse_for :: proc(p: ^Parser, header: string, start: int) -> ^For {
	node := new(For)
	node.header = header
	if header == "" {
		fail(p, start, "{{for}} needs a loop header, e.g. {{for item in items}}")
	}
	term: Terminator
	node.body, term = parse_nodes(p)
	if term.kind != .End_For {
		unexpected(p, term, start, "{for}", "{/for}")
	}
	return node
}

// Reports a block that was closed by the wrong terminator.
unexpected :: proc(p: ^Parser, term: Terminator, start: int, what, closer: string) {
	switch term.kind {
	case .EOF:       fail(p, start, "%s is never closed, expected %s", what, closer)
	case .Close_Tag: fail(p, term.pos, "expected %s before </%s>", closer, term.text)
	case .Else:      fail(p, term.pos, "expected %s before {{else}}", closer)
	case .End_If:    fail(p, term.pos, "expected %s before {{/if}}", closer)
	case .End_For:   fail(p, term.pos, "expected %s before {{/for}}", closer)
	}
}

// Parses an element starting at `<`. The result is wrapped in `For` and `If`
// nodes when the element has `:for` and `:if` attributes.
parse_element :: proc(p: ^Parser) -> Node {
	start := p.pos
	elem := new(Element)
	elem.line = line_at(p, start)
	p.pos += 1
	elem.tag = scan_while(p, is_tag_char)
	lower_tag := strings.to_lower(elem.tag)
	elem.void = contains(VOID_ELEMENTS, lower_tag)
	component := is_component(elem.tag)

	if_cond, for_header: string
	self_closing := false
	attrs: for {
		skip_space(p)
		if p.pos >= len(p.src) {
			fail(p, start, "unterminated <%s> tag", elem.tag)
			return elem
		}
		attr_start := p.pos
		attr := Attr{line = line_at(p, attr_start)}
		switch {
		case p.src[p.pos] == '>':
			p.pos += 1
			break attrs
		case strings.has_prefix(p.src[p.pos:], "/>"):
			p.pos += 2
			self_closing = true
			break attrs
		case p.src[p.pos] == '{':
			attr.kind = .Spread
			code, _ := scan_code(p)
			attr.value = strings.trim_space(code)
			if attr.value == "" {
				fail(p, attr_start, "empty {{}} in <%s>", elem.tag)
			}
			if component {
				fail(p, attr_start, "attributes cannot be spread on component <%s>", elem.tag)
			}
		case:
			attr.name = scan_while(p, is_attr_char)
			if attr.name == "" {
				fail(p, attr_start, "unexpected '%c' in <%s>", p.src[p.pos], elem.tag)
				return elem
			}
			attr.kind = .Bare
			skip_space(p)
			if p.pos < len(p.src) && p.src[p.pos] == '=' {
				p.pos += 1
				skip_space(p)
				if p.pos >= len(p.src) {
					continue
				}
				switch quote := p.src[p.pos]; quote {
				case '"', '\'':
					end := strings.index_byte(p.src[p.pos + 1:], quote)
					if end < 0 {
						fail(p, p.pos, "unterminated value of attribute '%s'", attr.name)
						return elem
					}
					attr.kind = .Static
					attr.value = p.src[p.pos + 1:][:end]
					p.pos += end + 2
				case '{':
					attr.kind = .Expr
					code, _ := scan_code(p)
					attr.value = strings.trim_space(code)
					if attr.value == "" {
						fail(p, attr_start, "empty value of attribute '%s'", attr.name)
					}
				case:
					attr.kind = .Static
					attr.value = scan_while(p, proc(c: byte) -> bool { return !is_space(c) && c != '>' })
				}
			}
		}

		switch {
		case attr.name == ":if" || attr.name == ":for":
			if attr.kind != .Expr {
				fail(p, attr_start, "%s needs a value in braces, e.g. %s={{...}}", attr.name, attr.name)
			}
			if attr.name == ":if" {
				if_cond = attr.value
			} else {
				for_header = attr.value
			}
		case component && !is_identifier(attr.name):
			fail(p, attr_start, "'%s' is not a valid argument name for component <%s>", attr.name, elem.tag)
		case:
			append(&elem.attrs, attr)
		}
	}

	switch {
	case self_closing || elem.void:
	case contains(RAW_TEXT_ELEMENTS, lower_tag):
		closer := strings.concatenate({"</", lower_tag})
		end := -1
		for i in p.pos ..= len(p.src) - len(closer) {
			if strings.equal_fold(p.src[i:][:len(closer)], closer) {
				end = i
				break
			}
		}
		close := strings.index_byte(p.src[max(end, 0):], '>')
		if end < 0 || close < 0 {
			fail(p, start, "<%s> is never closed", elem.tag)
			return elem
		}
		p.raw, p.raw_end = true, end
		term: Terminator
		elem.children, term = parse_nodes(p)
		p.raw = false
		expect_end(p, term)
		if p.error == "" {
			p.pos = end + close + 1
		}
	case:
		term: Terminator
		elem.children, term = parse_nodes(p)
		if term.kind != .Close_Tag || term.text != elem.tag {
			unexpected(p, term, start, fmt.aprintf("<%s>", elem.tag), fmt.aprintf("</%s>", elem.tag))
		}
	}

	// Like in HEEx, `:for` is the outer construct and `:if` filters its items.
	node: Node = elem
	if if_cond != "" {
		wrapper := new(If)
		branch := Branch{cond = if_cond}
		append(&branch.body, node)
		append(&wrapper.branches, branch)
		node = wrapper
	}
	if for_header != "" {
		wrapper := new(For)
		wrapper.header = for_header
		append(&wrapper.body, node)
		node = wrapper
	}
	return node
}

/*
Removes the line of a block tag or comment that stands alone on its line, so
that `{if}`, `{for}` and friends do not leave blank lines in the output.
`start` is the position of the tag, `p.pos` is just past its end.
*/
trim_standalone :: proc(p: ^Parser, text: ^strings.Builder, start: int) {
	i := start
	for i > 0 && (p.src[i - 1] == ' ' || p.src[i - 1] == '\t') {
		i -= 1
	}
	if i > 0 && p.src[i - 1] != '\n' {
		return
	}
	j := p.pos
	for j < len(p.src) && (p.src[j] == ' ' || p.src[j] == '\t' || p.src[j] == '\r') {
		j += 1
	}
	if j < len(p.src) && p.src[j] != '\n' {
		return
	}
	for len(text.buf) > 0 && (text.buf[len(text.buf) - 1] == ' ' || text.buf[len(text.buf) - 1] == '\t') {
		pop(&text.buf)
	}
	p.pos = min(j + 1, len(p.src))
}

// Scans `{code}` or `{{code}}` starting at `p.pos` and returns the code.
scan_code :: proc(p: ^Parser) -> (code: string, double: bool) {
	if !strings.has_prefix(p.src[p.pos:], "{{") {
		return scan_braces(p), false
	}
	start := p.pos
	p.pos += 1
	code = scan_braces(p, double = true)
	if p.error != "" {
		return "", true
	}
	if p.pos >= len(p.src) || p.src[p.pos] != '}' {
		fail(p, start, "'{{{{' must be closed by '}}}}'")
		return "", true
	}
	p.pos += 1
	return code, true
}

// Scans a balanced `{...}` starting at `p.pos` and returns what is between the braces.
// `double` is set when that brace is the inner one of a `{{`.
scan_braces :: proc(p: ^Parser, double := false) -> string {
	start := p.pos
	depth := 0
	for i := start; i < len(p.src); i += 1 {
		switch p.src[i] {
		case '{':
			depth += 1
		case '}':
			depth -= 1
			if depth == 0 {
				p.pos = i + 1
				return p.src[start + 1:i]
			}
		case '"', '\'', '`':
			i = skip_literal(p.src, i)
		case '/':
			if strings.has_prefix(p.src[i:], "/*") {
				end := strings.index(p.src[i:], "*/")
				i = len(p.src) if end < 0 else i + end + 1
			}
		}
	}
	if double {
		fail(p, start - 1, "unterminated '{{{{'")
	} else {
		fail(p, start, "unterminated '{{', write \\{{ for a literal brace")
	}
	return ""
}

// Returns the index of the closing quote of the string or rune literal starting at `s[i]`.
skip_literal :: proc(s: string, i: int) -> int {
	i := i
	quote := s[i]
	i += 1
	for i < len(s) && s[i] != quote {
		if s[i] == '\\' && quote != '`' {
			i += 1
		}
		i += 1
	}
	return i
}

// Index of `needle` in `s`, outside of any brackets and literals, or -1.
// With `word`, the match must also be a whole word.
top_level_index :: proc(s: string, needle: string, word := false) -> int {
	depth := 0
	for i := 0; i < len(s); i += 1 {
		if depth == 0 && strings.has_prefix(s[i:], needle) {
			end := i + len(needle)
			if !word || ((i == 0 || !is_ident_char(s[i - 1])) && (end == len(s) || !is_ident_char(s[end]))) {
				return i
			}
		}
		switch s[i] {
		case '(', '[', '{': depth += 1
		case ')', ']', '}': depth -= 1
		case '"', '\'', '`': i = skip_literal(s, i)
		}
	}
	return -1
}

split_top_level :: proc(s: string, separator: string) -> [dynamic]string {
	parts: [dynamic]string
	s := s
	for {
		i := top_level_index(s, separator)
		if i < 0 {
			break
		}
		append(&parts, s[:i])
		s = s[i + len(separator):]
	}
	if strings.trim_space(s) != "" {
		append(&parts, s)
	}
	return parts
}

/*
Names of the variables declared by the header of a `for` or `if`:
`item, i in items`, `i := 0; i < n; i += 1`, `value, ok := m[key]; ok`.
*/
header_vars :: proc(header: string, is_for: bool) -> [dynamic]string {
	names: string
	if semicolon := top_level_index(header, ";"); semicolon >= 0 {
		if declaration := top_level_index(header[:semicolon], ":="); declaration >= 0 {
			names = header[:declaration]
		}
	} else if is_for {
		if in_keyword := top_level_index(header, "in", word = true); in_keyword >= 0 {
			names = header[:in_keyword]
		}
	}
	vars: [dynamic]string
	for part in strings.split(names, ",") {
		name := strings.trim_space(strings.trim_prefix(strings.trim_space(part), "&"))
		if is_identifier(name) && name != "_" {
			append(&vars, name)
		}
	}
	return vars
}

// A tag with a dot is a component: `<.card>` calls `card`, `<ui.card>` calls `ui.card`.
is_component :: proc(tag: string) -> bool {
	return strings.contains_rune(tag, '.')
}

has_keyword :: proc(s, keyword: string) -> bool {
	return strings.has_prefix(s, keyword) && (len(s) == len(keyword) || !is_ident_char(s[len(keyword)]))
}

scan_while :: proc(p: ^Parser, predicate: proc(c: byte) -> bool) -> string {
	start := p.pos
	for p.pos < len(p.src) && predicate(p.src[p.pos]) {
		p.pos += 1
	}
	return p.src[start:p.pos]
}

skip_space :: proc(p: ^Parser) {
	scan_while(p, is_space)
}

contains :: proc(list: []string, s: string) -> bool {
	for item in list {
		if item == s {
			return true
		}
	}
	return false
}

is_space :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

is_alpha :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_ident_char :: proc(c: byte) -> bool {
	return is_alpha(c) || (c >= '0' && c <= '9') || c == '_' || c >= 0x80
}

is_tag_char :: proc(c: byte) -> bool {
	return is_ident_char(c) || c == '-' || c == ':' || c == '.'
}

is_attr_char :: proc(c: byte) -> bool {
	return !is_space(c) && !strings.contains_rune("=>/\"'{<", rune(c))
}

is_identifier :: proc(s: string) -> bool {
	if s == "" || (s[0] >= '0' && s[0] <= '9') {
		return false
	}
	for i in 0 ..< len(s) {
		if !is_ident_char(s[i]) {
			return false
		}
	}
	return true
}
