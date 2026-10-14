# frigg

An HTML template compiler for [Odin](https://odin-lang.org), in the spirit of
Phoenix's HEEx templates. `*.frigg` templates are compiled to Odin procedures
that return the template as a tree of nodes, which can be inspected or
serialized to HTML.

- `compiler/` — the `frigg` compiler
- `frigg/` — the runtime package imported by the generated code and by your program
- `example/` — a small program using both
- `tests/` — end-to-end and runtime tests

## Building

```sh
odin build compiler -out:bin/frigg
```

## Testing

```sh
odin test compiler   # parser and code generator
odin test tests      # runtime library, and rendering of compiled templates
```

`tests/templates.odin` is generated from `tests/templates/*.frigg` and checked
in. After changing those templates or the code generator, regenerate it with
`./bin/frigg -r -import:./frigg tests/templates`; `odin test compiler` fails
while it is stale. `./test.sh` builds the compiler, regenerates, and runs both.

## Usage

```sh
frigg [-r] [-package:<name>] [-import:<path>] <directory>...
```

`frigg ./frontend/templates` compiles every `*.frigg` file directly inside
`./frontend/templates` into the single file `./frontend/templates.odin`. Each
template becomes a procedure named after its file (`index.frigg` → `index`).

| Option | |
|---|---|
| `-r`, `-R` | Repeat for every subdirectory: `templates/admin/*.frigg` → `templates/admin.odin`. |
| `-package:<name>` | Package of the generated files. Defaults to the package declared by the Odin files next to the generated file, else the name of the directory it is written to. |
| `-import:<path>` | Import path of the runtime package, `shared:frigg` by default. A path without a collection (`-import:./vendor/frigg`) is taken from the current directory and rewritten to be relative to each generated file. |

Note that `templates.odin` is written *next to* the `templates` directory, so
it belongs to the package of the parent directory, and with `-r`,
`templates/admin.odin` belongs to the package of the `templates` directory.

A generated file is left untouched when its content would not change.

## Template syntax

```html
{# args: title: string, users: []User #}
{# import "core:fmt" #}
<.layout title={title}>
  <h1 class="title" id={fmt.tprintf("page-%d", len(users))}>Hello, {title}!</h1>
  {if len(users) == 0}
    <p>Nobody is here.</p>
  {else}
    <ul>
      <li :for={user, i in users} :if={user.active} class={"odd" if i % 2 == 1 else "even"}>
        <.user_card user={user} highlighted={i == 0} />
      </li>
    </ul>
  {/if}
</.layout>
```

### Arguments

The first line can be a magic comment declaring the arguments of the template.
What follows `args:` is an Odin parameter list (optionally in parentheses), so
default values work as usual:

```
{# args: title: string, users: []User, compact := false #}
```

The generated procedure takes these parameters followed by
`allocator := context.temp_allocator` (unless you declare an `allocator`
argument yourself):

```odin
index :: proc(title: string, users: []User, compact := false, allocator := context.temp_allocator) -> frigg.Template
```

`{# import "core:fmt" #}` adds an import to the generated file. The runtime is
always imported as `frigg`. Any other `{# ... #}` is a comment that never
reaches the output.

### Elements and text

HTML elements become `^frigg.Element` nodes holding their tag, attributes and
children. All static text (including HTML comments and `<!DOCTYPE>`) becomes
`frigg.Safe_String` nodes that are written verbatim.

- Tags must be closed explicitly, except void elements (`<br>`, `<img>`...).
  `<div />` is the same as `<div></div>`.
- The content of `<script>` and `<style>` is raw text: braces are not code.
- Write `\{` for a literal `{`.

### Code

`{expression}` becomes a `frigg.Code` node: a pointer to a generated procedure
containing the expression, and a pointer to a snapshot of the template
variables. The procedure is only called when the tree is serialized or walked.
The result goes through `frigg.to_node`:

| Result | Serialized as |
|---|---|
| `frigg.Safe_String` | verbatim |
| `frigg.Node`, `frigg.Template`, `^frigg.Element`, `[]frigg.Node` | that subtree |
| anything else | formatted with `core:fmt`, then HTML escaped |

### Attributes

| Syntax | |
|---|---|
| `class="title"` | static, written verbatim |
| `disabled` | boolean attribute |
| `class={expression}` | `frigg.Code`; the result is escaped, `true` writes the bare attribute, `false` or `nil` omits it |
| `{expression}` | spread of a `[]frigg.Attribute`, `frigg.Attribute` or `map[string]string` |

### Control flow

```
{if condition} ... {else if condition} ... {else} ... {/if}
{for item, i in items} ... {/for}
<li :for={item in items} :if={item.visible}>...</li>
```

Conditions and loop headers are plain Odin (`{if value, ok := m[key]; ok}`,
`{for i in 0..<10}`). When an element has both, `:for` loops and `:if` filters
its items. A block tag alone on its line does not leave a blank line behind.

Control flow runs when the template procedure is called and builds the tree;
only `{expression}`s are deferred. Each loop iteration snapshots the visible
variables for the code it contains.

### Components

A tag containing a dot calls another template (or any procedure with the same
shape): `<.card>` calls `card`, `<ui.card>` calls `ui.card`. Attributes are
passed as named arguments, and the content of the tag, if any, as `children`:

```html
{# args: title: string, children: frigg.Node #}
<section><h2>{title}</h2>{children}</section>
```

```html
<.card title="Users"><p>{len(users)} users</p></.card>
```

Since templates are plain procedures, `{card("Users", nil)}` works too.

## Runtime

```odin
import frigg "shared:frigg"

page := index("Asgard", users)                 // builds the tree
html := frigg.to_string(page)                  // serialize to a string
frigg.write(writer, page)                      // or to any io.Writer
frigg.write_to_builder(&builder, page)         // or to a strings.Builder
frigg.walk(page, visitor, &user_data)          // visit every node
```

```odin
Node :: union {Safe_String, string, bool, ^Element, Code, Template, []Node}
```

A tree can also be traversed by hand with a `switch` on `Node`; `frigg.eval`
runs a `Code` node and returns its result.

Trees are allocated with the `allocator` argument of the template, the
temporary allocator by default, and are meant to be freed all at once
(`free_all(context.temp_allocator)`, or an arena). Values formatted during
serialization use `context.temp_allocator`.

## Limitations

- Errors in template code are reported by the Odin compiler against the
  generated file; each generated procedure is annotated with its
  `template.frigg:line`.
- An untyped string literal is ambiguous between `string` and `Safe_String`
  when converted to a `frigg.Node` or attribute value directly: write
  `string("text")` or `frigg.Safe_String("text")`. `{"text"}` in a template
  is fine.
- Identifiers starting with an underscore (`_n1`, `_env0`...) are used by the
  generated code.
- A variable used only by code inside a nested loop still counts as unused
  for `-vet` if nothing else in its own scope reads it.
