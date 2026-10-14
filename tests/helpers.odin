// Package tests holds the end-to-end tests of frigg: the templates of
// `templates/` are compiled to `templates.odin` and rendered by the tests.
package tests

// Called by `templates/deferred.frigg` to observe when its code runs.
bump :: proc(counter: ^int) -> int {
	counter^ += 1
	return counter^
}
