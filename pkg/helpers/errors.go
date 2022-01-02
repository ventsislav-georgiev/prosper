package helpers

import "errors"

var (
	ErrSkip  = errors.New("non null error")
	ErrEmpty = errors.New("")
)
