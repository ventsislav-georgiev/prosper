package units

import (
	"strconv"
	"strings"

	u "github.com/bcicen/go-units"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
)

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	isDigit := expr[0] >= 48 && expr[0] <= 57
	if !isDigit {
		return "", nil, nil, helpers.ErrSkip
	}

	parts := strings.Split(strings.ToLower(expr), " ")
	if len(parts) != 4 {
		return "", nil, nil, helpers.ErrSkip
	}

	if parts[2] != "in" && parts[2] != "to" {
		return "", nil, nil, helpers.ErrSkip
	}

	from, err := u.Find(parts[1])
	if err != nil {
		return "", nil, nil, helpers.ErrSkip
	}

	to, err := u.Find(parts[3])
	if err != nil {
		return "", nil, nil, helpers.ErrSkip
	}

	val, err := strconv.ParseFloat(parts[0], 64)
	if err != nil {
		return "", nil, nil, helpers.ErrSkip
	}

	r, err := u.ConvertFloat(val, from, to)
	if err != nil {
		return "", nil, nil, helpers.ErrSkip
	}

	return r.String(), nil, nil, nil
}
