package mathexpr

import (
	"fmt"
	"strconv"

	"github.com/Knetic/govaluate"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
)

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	isDigit := expr[0] >= 48 && expr[0] <= 57
	if !isDigit && expr[0] != '(' {
		return "", nil, nil, helpers.ErrSkip
	}

	e, err := govaluate.NewEvaluableExpression(expr)
	if err != nil {
		return "", nil, nil, err
	}

	r, err := e.Eval(nil)
	if err != nil {
		return err.Error(), nil, nil, nil
	}

	switch f := r.(type) {
	case float32:
		return strconv.FormatFloat(float64(f), 'f', -1, 32), nil, nil, nil
	case float64:
		return strconv.FormatFloat(f, 'f', -1, 64), nil, nil, nil
	default:
		return fmt.Sprintf("%v", r), nil, nil, nil
	}
}
