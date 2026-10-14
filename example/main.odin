package example

import "core:fmt"
import "core:os"

import frigg "../frigg"
import admin "templates"

User :: struct {
	name:   string,
	age:    int,
	email:  Maybe(string),
	active: bool,
	tags:   []string,
}

main :: proc() {
	users := []User {
		{name = "Odin <Allfather>", age = 5000, email = "odin@asgard.example", active = true, tags = {"wise", "one-eyed"}},
		{name = "Loki", age = 3000, active = false},
		{name = "Freyja & Co", age = 2500, active = true, tags = {"vanir"}},
	}

	// Calling a template only builds its tree...
	page := index("Asgard", users, {{"class", string("users")}, {"data-note", string(`"quoted"`)}})

	// ...which can be inspected,
	count_elements :: proc(node: frigg.Node, depth: int, user_data: rawptr) -> bool {
		if _, ok := node.(^frigg.Element); ok {
			(^int)(user_data)^ += 1
		}
		return true
	}
	elements := 0
	frigg.walk(page, count_elements, &elements)
	fmt.eprintfln("%d elements", elements)

	// serialized to a string,
	html := frigg.to_string(page)
	defer delete(html)
	fmt.print(html)

	// or written to any io.Writer.
	counts := map[string]int{}
	defer delete(counts)
	counts["users"] = len(users)
	frigg.write(os.to_stream(os.stdout), admin.dashboard(counts))

	free_all(context.temp_allocator)
}
