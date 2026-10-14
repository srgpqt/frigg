/*
frigg compiles the `*.frigg` HTML templates of a directory into a single Odin
file named after the directory: `frigg ./frontend/templates` writes
`./frontend/templates.odin`. See the README for the template syntax.
*/
package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

USAGE :: `Usage: frigg [options] <directory>...

Compiles the *.frigg templates of each directory into <directory>.odin,
next to the directory.

Options:
  -r, -R           also compile the templates of every subdirectory, each
                   into its own <subdirectory>.odin
  -package:<name>  package of the generated files (default: the package of
                   the Odin files next to the generated file, else the name
                   of the directory it is written to)
  -import:<path>   import path of the frigg runtime package (default:
                   "shared:frigg"); a path without a collection is taken from
                   the current directory and rewritten to be relative to
                   each generated file
`

Options :: struct {
	recursive:    bool,
	package_name: string,
	import_path:  string,
}

main :: proc() {
	// The compiler is short lived: everything is allocated in one arena and never freed.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) == nil {
		context.allocator = virtual.arena_allocator(&arena)
	}

	opts := Options{import_path = "shared:frigg"}
	dirs: [dynamic]string
	for arg in os.args[1:] {
		switch {
		case arg == "-r" || arg == "-R":
			opts.recursive = true
		case strings.has_prefix(arg, "-package:"):
			opts.package_name = arg[len("-package:"):]
		case strings.has_prefix(arg, "-import:"):
			opts.import_path = arg[len("-import:"):]
		case arg == "-h" || arg == "-help" || arg == "--help":
			fmt.print(USAGE)
			return
		case strings.has_prefix(arg, "-"):
			fmt.eprintfln("frigg: unknown option '%s'\n", arg)
			fmt.eprint(USAGE)
			os.exit(2)
		case:
			append(&dirs, arg)
		}
	}
	if len(dirs) == 0 {
		fmt.eprint(USAGE)
		os.exit(2)
	}

	ok := true
	for dir in dirs {
		if !process_dir(dir, opts) {
			ok = false
		}
	}
	os.exit(0 if ok else 1)
}

// Compiles the templates of `dir` and, with `-r`, of its subdirectories.
process_dir :: proc(dir: string, opts: Options) -> (ok: bool) {
	display := strings.trim_right(dir, "/\\")
	if display == "" {
		display = dir
	}
	abs, abs_err := os.get_absolute_path(dir, context.allocator)
	if abs_err != nil || !os.is_dir(abs) {
		fmt.eprintfln("frigg: '%s' is not a directory", dir)
		return false
	}
	entries, read_err := os.read_all_directory_by_path(abs, context.allocator)
	if read_err != nil {
		fmt.eprintfln("frigg: cannot read '%s': %s", dir, os.error_string(read_err))
		return false
	}

	files, subdirs: [dynamic]string
	for entry in entries {
		switch {
		case os.is_dir(entry.fullpath):
			if !strings.has_prefix(entry.name, ".") {
				append(&subdirs, entry.name)
			}
		case strings.has_suffix(entry.name, ".frigg"):
			append(&files, entry.name)
		}
	}
	slice.sort(files[:])
	slice.sort(subdirs[:])

	ok = true
	if len(files) > 0 {
		ok = compile_dir(abs, display, files[:], opts)
	}
	if opts.recursive {
		for subdir in subdirs {
			if !process_dir(fmt.aprintf("%s/%s", display, subdir), opts) {
				ok = false
			}
		}
	}
	return ok
}

// Compiles the given templates of directory `dir` into `dir + ".odin"`.
compile_dir :: proc(dir, display: string, files: []string, opts: Options) -> bool {
	abs := strings.trim_right(dir, "/\\")
	dir_name := base_name(abs)
	if dir_name == "" {
		fmt.eprintfln("frigg: cannot name the output file of '%s'", display)
		return false
	}
	out := strings.concatenate({abs, ".odin"})
	out_dir := abs[:len(abs) - len(dir_name)]
	out_dir = strings.trim_right(out_dir, "/\\") if len(out_dir) > 1 else out_dir

	ok := true
	templates: [dynamic]^Template
	for file in files {
		path := fmt.aprintf("%s/%s", display, file)
		data, err := os.read_entire_file(fmt.aprintf("%s/%s", abs, file), context.allocator)
		if err != nil {
			fmt.eprintfln("frigg: cannot read '%s': %s", path, os.error_string(err))
			ok = false
			continue
		}
		name := procedure_name(strings.trim_suffix(file, ".frigg"))
		for other in templates {
			if other.name == name {
				fmt.eprintfln("%s: procedure '%s' is already generated from %s", path, name, other.path)
				ok = false
			}
		}
		tmpl, error := parse_template(path, name, string(data))
		if error != "" {
			fmt.eprintln(error)
			ok = false
		}
		append(&templates, tmpl)
	}
	if !ok {
		return false
	}

	package_name := opts.package_name
	if package_name == "" {
		package_name = detect_package(out_dir, out)
	}
	if package_name == "" {
		package_name = procedure_name(base_name(out_dir))
	}

	import_path := opts.import_path
	if !strings.contains_rune(import_path, ':') {
		// Without a collection, the path is given from the current directory,
		// but Odin resolves it from the directory of the importing file.
		target, target_err := os.get_absolute_path(import_path, context.allocator)
		relative, relative_err := os.get_relative_path(out_dir, target, context.allocator)
		if target_err != nil || relative_err != nil {
			fmt.eprintfln("frigg: cannot resolve import path '%s' from '%s'", import_path, out_dir)
			return false
		}
		import_path, _ = strings.replace_all(relative, "\\", "/")
		if !strings.has_prefix(import_path, ".") {
			import_path = strings.concatenate({"./", import_path})
		}
	}

	source := generate(templates[:], dir_name, package_name, import_path)

	shown := out
	if cwd, cwd_err := os.get_working_directory(context.allocator); cwd_err == nil {
		if relative, relative_err := os.get_relative_path(cwd, out, context.allocator); relative_err == nil {
			shown = relative
		}
	}
	// Leave an up to date file untouched, to keep build systems quiet.
	if existing, err := os.read_entire_file(out, context.allocator); err == nil && string(existing) == source {
		fmt.printfln("frigg: %s is up to date", shown)
		return true
	}
	if err := os.write_entire_file(out, source); err != nil {
		fmt.eprintfln("frigg: cannot write '%s': %s", shown, os.error_string(err))
		return false
	}
	fmt.printfln("frigg: wrote %s (%d template%s)", shown, len(templates), "" if len(templates) == 1 else "s")
	return true
}

// Finds the package declared by the Odin files of `dir`, ignoring the file `except`.
detect_package :: proc(dir, except: string) -> string {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return ""
	}
	for entry in entries {
		if !strings.has_suffix(entry.name, ".odin") || entry.name == base_name(except) {
			continue
		}
		data, read_err := os.read_entire_file(entry.fullpath, context.allocator)
		if read_err != nil {
			continue
		}
		text := string(data)
		for raw_line in strings.split_lines_iterator(&text) {
			line := strings.trim_space(raw_line)
			if has_keyword(line, "package") {
				name := strings.trim_space(line[len("package"):])
				if end := strings.index_any(name, " \t;/"); end >= 0 {
					name = name[:end]
				}
				if is_identifier(name) {
					return name
				}
			}
		}
	}
	return ""
}

// Turns a file or directory name into a valid Odin identifier.
procedure_name :: proc(name: string) -> string {
	sb: strings.Builder
	if name == "" || (name[0] >= '0' && name[0] <= '9') {
		strings.write_byte(&sb, '_')
	}
	for i in 0 ..< len(name) {
		strings.write_byte(&sb, name[i] if is_ident_char(name[i]) else '_')
	}
	return strings.to_string(sb)
}

// Last element of a path.
base_name :: proc(path: string) -> string {
	return path[strings.last_index_any(path, "/\\") + 1:]
}
